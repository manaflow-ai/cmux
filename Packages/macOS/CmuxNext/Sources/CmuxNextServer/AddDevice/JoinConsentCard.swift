import CmuxNextCompat
public import CmuxNextPages
public import CmuxNextSettings
public import AppKit
public import Foundation

/// The join consent's one-time ask on the server card page (`#/join-consent`,
/// webviews/src/pages/server-cards/join-consent): the first request acpmux refused with
/// `consent_required` asks the person at this Mac once (``JoinConsentModel/refused(_:)``). Swift keeps
/// the decision (``JoinConsentModel``: the person line, the grant gate, the device owner's confirm);
/// the page draws who asked for what, the question, the note, why an Allow did not take, and Deny.
/// - `status` → `{ask: {requester, surface} | null, error: string | null, writing}`;
/// - `deny` → closes the ask, writing nothing (the person's own click or key);
/// - stream `changes` → one empty event whenever `status` may have changed.
///
/// SECURITY: Allow is no page control. It is the panel's native click-only button (``PersonControl``,
/// named here while an ask shows, off while a write is in flight), and only the person's own click on
/// it grants (``personPressed()``, checked by the panel's dispatch: from the HID system, down and up on
/// the button; no key, script, Accessibility press, posted event or Computer Use click). The model then
/// asks the device owner (Touch ID or the login password) before it sends.
///
/// Its panel is its own (``WebCardPanel/joinConsent(model:isPersonEvent:)``): cmux's own screen sharing and recorders
/// leave it out and Computer Use refuses it; another app's capture is not guaranteed to miss it (macOS 15.4+).
@MainActor
public final class JoinConsentCardProvider: WebCard {
    public static let route = "join-consent"
    static let statusOp = "cmux.joinConsent.status"
    static let denyOp = "cmux.joinConsent.deny"
    static let changesStream = "cmux.joinConsent.changes"

    public var card: String { Self.route }
    public var prefix: String { "cmux.joinConsent." }
    public weak var host: WebCardPanel?

    public let model: JoinConsentModel

    public init(model: JoinConsentModel) {
        self.model = model
    }

    public func opened(again: Bool) {
        host?.setPersonControl(personControl, card: card)
    }

    /// Only the model closes the ask (Deny, Allow, the Labs switch off).
    public func closed() {}

    public func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        switch op {
        case Self.statusOp:
            return Self.status(model)
        case Self.denyOp:
            guard context.userGesture else { throw Self.refused }
            guard model.ask != nil, !model.writing else { return .null }
            // task-owner: one answer per press; the ask hides at once
            Task { [model] in await model.answer(allow: false) }
            return .null
        default:
            throw PageError.unknownOp(op)
        }
    }

    /// SECURITY: the person clicked the native Allow (the panel checked the click). Allow is off while
    /// a write is in flight, so no click lands over a grant still landing.
    public func personPressed() {
        guard model.ask != nil, !model.writing else { return }
        // task-owner: one answer per click; the write ends on its own
        Task { [model] in await model.answer(allow: true) }
    }

    /// The native Allow while an ask shows, off while a write is in flight; none otherwise.
    var personControl: PersonControl? {
        model.ask == nil ? nil : PersonControl(title: JoinConsentStrings.allow, isEnabled: !model.writing)
    }

    public func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                          onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
        guard stream == Self.changesStream else { throw PageError.unknownOp(stream) }
        let model = model
        // task-owner: lives as long as the page's subscription; event-driven (Observation)
        let task = Task { [weak self] in
            var last: JSONValue?
            for await state in ObservationStream({ Self.status(model) }) {
                guard !Task.isCancelled else { return }
                if state == last { continue }
                guard let self else { return }
                // The first value is the state the page reads with `status`; only changes are events.
                if last != nil {
                    // A new ask or a new answer draws anew: a click begun before it is not aimed at it.
                    self.host?.rearm()
                    onEvent(.object([:]))
                }
                self.host?.setPersonControl(self.personControl, card: self.card)
                last = state
            }
        }
        return PageSubscription { task.cancel() }
    }

    static var refused: PageError {
        PageError(code: PageNativeOp.userOnlyCode, message: JoinConsentStrings.clickOnly)
    }

    static func status(_ model: JoinConsentModel) -> JSONValue {
        var ask: JSONValue = .null
        if let refusal = model.ask {
            ask = ["requester": .string(refusal.requester), "surface": .string(refusal.surface.rawValue)]
        }
        return ["ask": ask, "error": model.askError.map { .string($0) } ?? .null, "writing": .bool(model.writing)]
    }
}

extension WebCardPanel {
    /// The join consent ask's own card panel: the server card page on `#/join-consent`, at the top right
    /// of the main screen over every app and full screen, never activating cmux or taking the keys.
    /// SECURITY (cmux#33066, HQ#5121): every capture cmux makes leaves the panel out by its window id
    /// (``CaptureExcludedWindows``: screen sharing, `cmux rd serve`, the recorders), and Computer Use
    /// refuses the window (MacCuaTargetResolver) and captures only its own target window. `sharingType = .none`
    /// asks every other capture to skip it too, but since macOS 15.4 another app's ScreenCaptureKit capture
    /// may still show it: what keeps Allow the person's is that it takes only the person's own click on it,
    /// read from the HID system (``WebCard/personPressed()``), never a capture's absence.
    /// `isPersonEvent` is the person check (the app's strict HID-source `PersonInputCheck`).
    @MainActor
    public static func joinConsent(model: JoinConsentModel, isPersonEvent: @escaping @MainActor (NSEvent) -> Bool) -> WebCardPanel? {
        guard let panel = WebCardPanel(descriptor: .serverCards, cards: [JoinConsentCardProvider(model: model)], width: joinConsentWidth)
        else { return nil }
        panel.isPersonEvent = isPersonEvent
        panel.configureForJoinConsent()
        return panel
    }

    static let joinConsentWidth: CGFloat = 380
    /// The gap between the screen's top right corner and the ask.
    static let joinConsentInset: CGFloat = 16

    /// What sets the join consent ask's panel apart from the server cards' (its tests check it).
    @MainActor
    func configureForJoinConsent() {
        sharingType = .none
        level = .statusBar
        // A click on Allow makes the panel key (cmux stays inactive): the panel takes a grant's click only while key.
        becomesKeyOnlyIfNeeded = false
        isMovableByWindowBackground = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        setAccessibilityIdentifier("cmux.joinConsentAsk")
        ordersFrontRegardless = true
        // Only Deny, Allow or the model closes the ask: Escape never hides it, even before the page listens.
        cancelHides = false
        place = { size, _, _ in Self.joinConsentPlacement(size: size, in: (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame) }
    }

    /// The top right of `visible` (the main screen's), ``joinConsentInset`` in from both edges.
    static func joinConsentPlacement(size: CGSize, in visible: NSRect?) -> NSRect {
        let area = visible ?? NSRect(origin: .zero, size: size)
        return NSRect(x: area.maxX - size.width - joinConsentInset, y: area.maxY - size.height - joinConsentInset,
                      width: size.width, height: size.height)
    }
}
