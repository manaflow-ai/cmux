import AppKit
import CmuxFoundation
import CmuxSettings

/// Main-actor coordinator for the optional global leader-key chord layer.
///
/// The coordinator owns platform concerns (NSEvent conversion, a cancellable
/// one-shot deadline, and the HUD) while ``ShortcutPrefixChordRouter`` owns the
/// deterministic matching contract. Executed bindings are handed back to the
/// existing AppDelegate shortcut dispatcher, so menu, command-palette,
/// configured-action, and numbered-action paths retain one execution route.
@MainActor
final class ShortcutPrefixChordCoordinator {
    enum OfferResult {
        case passThrough
        case duplicatePassThrough
        case consume
        case execute(ShortcutPrefixChordBinding)
        case mismatchPassThrough
    }

    private var router = ShortcutPrefixChordRouter()
    /// Allocated only after the first prefix is armed, preserving the
    /// default-off terminal fast path and avoiding a permanent timer source.
    private var expiryTimer: MainActorCoalescingDeadlineTimer<ShortcutPrefixChordCoordinator>?
    private let hud = ShortcutPrefixHUD()
    private weak var owner: AppDelegate?

    init(owner: AppDelegate) {
        self.owner = owner
        router.setPrefix(prefixStroke(from: KeyboardShortcutSettings.prefixShortcut()))
    }

    var isArmed: Bool { router.isArmed }

    /// Whether the configured leader layer needs to inspect key events.
    ///
    /// This remains false for the default-off configuration so AppKit's normal
    /// shortcut path pays no prefix-layer work. Once enabled, every event is
    /// offered to the bounded router ledger; replayed pass-through events then
    /// become no-ops instead of running cmux actions twice.
    var isEnabled: Bool { router.configuredPrefix != nil || router.isArmed }

    /// Refreshes the cached prefix after the settings store publishes a change.
    /// Keeping this out of the per-keystroke path preserves the terminal typing
    /// fast path while still allowing an initially disabled layer to be enabled
    /// without restarting the app.
    func refreshConfiguration() {
        let configuredPrefix = prefixStroke(from: KeyboardShortcutSettings.prefixShortcut())
        guard router.configuredPrefix != configuredPrefix else { return }
        router.setPrefix(configuredPrefix)
        cancelExpiry()
        hud.hide()
    }

    func offer(_ event: NSEvent) -> OfferResult {
        guard let owner else {
            return .passThrough
        }

        let eventWindowID = windowID(for: event)
        let eventID = eventIdentity(for: event, windowID: eventWindowID)
        let now = ProcessInfo.processInfo.systemUptime

        let configuredPrefix = router.configuredPrefix

        // A recognized media key is a valid suffix in the existing shortcut
        // model even though AppKit delivers it as `.systemDefined`. Convert it
        // through the same recorder adapter used by ordinary shortcuts. Any
        // other system-defined event remains unsupported and fail-closed.
        guard event.type == .keyDown else {
            guard event.type == .systemDefined else { return .passThrough }
            if let recorded = ShortcutStroke.from(event: event, requireModifier: false) {
                let stroke = recorded.cmuxSettingsShortcutStroke
                guard configuredPrefix != nil || router.isArmed else {
                    return .passThrough
                }
                return handle(
                    stroke: stroke,
                    event: event,
                    owner: owner,
                    eventWindowID: eventWindowID,
                    eventID: eventID,
                    now: now,
                    isEscape: false
                )
            }
            let unsupported = router.handleUnsupportedOnce(
                now: now,
                windowID: eventWindowID,
                eventID: eventID
            )
            return offerResult(for: unsupported)
        }

        let isEscape = ShortcutStroke.isEscapeCancelEvent(event)
        let stroke: CmuxSettings.ShortcutStroke
        if isEscape {
            // The app-target recorder intentionally rejects Escape. The prefix
            // state machine needs a sentinel stroke so Escape can cancel an
            // armed layer without ever becoming a bindable suffix.
            stroke = CmuxSettings.ShortcutStroke(key: "escape")
        } else if let recorded = ShortcutStroke.from(event: event, requireModifier: false) {
            stroke = recorded.cmuxSettingsShortcutStroke
        } else {
            let unsupported = router.handleUnsupportedOnce(
                now: now,
                windowID: eventWindowID,
                eventID: eventID
            )
            return offerResult(for: unsupported)
        }

        // The common default-off path must not resolve focus or scan every
        // action binding for every terminal keystroke.
        guard configuredPrefix != nil || router.isArmed else {
            return .passThrough
        }

        return handle(
            stroke: stroke,
            event: event,
            owner: owner,
            eventWindowID: eventWindowID,
            eventID: eventID,
            now: now,
            isEscape: isEscape
        )
    }

    /// Records an event that is intentionally outside the prefix layer's
    /// ownership boundary (modal UI, browser focus mode, or active IME).
    ///
    /// The first event continues through the ordinary dispatcher; an AppKit
    /// replay is reported as a duplicate pass-through so it cannot dispatch a
    /// second cmux action.
    func offerBypassed(_ event: NSEvent) -> OfferResult {
        guard event.type == .keyDown, isEnabled else { return .passThrough }
        let identity = eventIdentity(for: event, windowID: windowID(for: event))
        let result: ShortcutPrefixChordRouter.HandleResult
        if router.isArmed {
            // An ownership boundary arriving while armed cancels the pending
            // layer just like an unrepresentable suffix; the user's byte still
            // continues to the focused responder.
            result = router.handleUnsupportedOnce(
                now: ProcessInfo.processInfo.systemUptime,
                windowID: windowID(for: event),
                eventID: identity
            )
        } else {
            result = router.rememberBypassedEvent(eventID: identity)
        }
        return offerResult(for: result)
    }

    private func offerResult(
        for handled: ShortcutPrefixChordRouter.HandleResult
    ) -> OfferResult {
        let result = handled.result

        switch result {
        case let .armed(_, expiresAt):
            if !handled.wasDuplicate {
                scheduleExpiry(at: expiresAt)
                // The anchor is updated by the caller for a real event. A
                // replay only needs to consume; it must not rebuild HUD state.
            } else if !router.isArmed {
                // ``handleOnce`` expires state before resolving a replay. The
                // ledger still returns the original consumed decision, but
                // the presentation must follow the live state rather than
                // leaving a stale HUD/timer visible until another event.
                cancelExpiry()
                hud.hide()
            }
            return .consume
        case let .executed(binding):
            if handled.wasDuplicate {
                return .consume
            }
            cancelExpiry()
            hud.hide()
            return .execute(binding)
        case let .disarmed(consume):
            cancelExpiry()
            hud.hide()
            return consume ? .consume : .passThrough
        case .mismatchPassThrough:
            cancelExpiry()
            hud.hide()
            return handled.wasDuplicate ? .duplicatePassThrough : .mismatchPassThrough
        case .passThrough:
            if !router.isArmed {
                // A timeout or a window change can clear the pending state and
                // still produce ordinary pass-through for the current event.
                // Tear down the one-shot presentation immediately.
                cancelExpiry()
                hud.hide()
            }
            return handled.wasDuplicate ? .duplicatePassThrough : .passThrough
        }
    }

    func reset() {
        cancelExpiry()
        router.reset()
        hud.hide()
    }

    private func scheduleExpiry(at deadline: TimeInterval) {
        let delay = max(deadline - ProcessInfo.processInfo.systemUptime, 0.001)
        if expiryTimer == nil {
            expiryTimer = MainActorCoalescingDeadlineTimer(owner: self) { owner in
                owner.expireIfNeeded()
            }
        }
        expiryTimer?.schedule(after: .milliseconds(Int((delay * 1_000).rounded(.up))))
    }

    private func expireIfNeeded() {
        guard router.expire(now: ProcessInfo.processInfo.systemUptime) != nil else { return }
        cancelExpiry()
        hud.hide()
    }

    private func cancelExpiry() {
        expiryTimer?.cancel()
    }

    /// Routes a normalized stroke through the shared router and presents the
    /// available-suffix HUD whenever a new prefix is armed.
    private func handle(
        stroke: CmuxSettings.ShortcutStroke,
        event: NSEvent,
        owner: AppDelegate,
        eventWindowID: Int?,
        eventID: ShortcutPrefixChordEventIdentity,
        now: TimeInterval,
        isEscape: Bool
    ) -> OfferResult {
        let pendingIsLive = router.deadline.map { now < $0 } ?? false
        let pendingBelongsToEventWindow = router.pendingWindowID == eventWindowID
        let eligibleBindings: [ShortcutPrefixChordBinding]
        if (pendingIsLive && pendingBelongsToEventWindow)
            || !router.matchesConfiguredPrefix(stroke) {
            eligibleBindings = []
        } else {
            eligibleBindings = bindings(for: event, owner: owner)
        }
        let handled = router.handleOnce(
            stroke: stroke,
            now: now,
            windowID: eventWindowID,
            isEscape: isEscape,
            bindings: eligibleBindings,
            eventID: eventID
        )
        let result = offerResult(for: handled)
        if case .armed = handled.result, !handled.wasDuplicate {
            hud.show(
                bindings: router.availableBindings,
                anchorWindow: event.window
                    ?? owner.resolvedShortcutEventWindow(event)
                    ?? NSApp.keyWindow
            )
        }
        return result
    }

    private func bindings(
        for event: NSEvent,
        owner: AppDelegate
    ) -> [ShortcutPrefixChordBinding] {
        let context = owner.shortcutEventFocusContext(event).shortcutContext
        var result: [ShortcutPrefixChordBinding] = []
        result.reserveCapacity(KeyboardShortcutSettings.Action.allCases.count)

        for action in KeyboardShortcutSettings.Action.allCases {
            guard !action.isSystemWideHotkey,
                  action.allowsChordShortcut,
                  let shortcut = KeyboardShortcutSettings.shortcutIfBound(for: action),
                  shortcut.hasChord,
                  KeyboardShortcutSettings.effectiveWhenClause(for: action).evaluate(context) else {
                continue
            }
            guard let binding = ShortcutPrefixChordBinding(
                actionID: action.rawValue,
                shortcut: shortcut.cmuxSettingsStoredShortcut,
                label: action.label,
                matchesNumberedDigits: action.usesNumberedDigitMatching,
                hasPriorityRouting: action.hasPriorityShortcutRouting
            ) else {
                continue
            }
            result.append(binding)
        }

        if let context = owner.preferredMainWindowContextForShortcutRouting(event: event) {
            for action in owner.configuredCmuxShortcutActions(for: context) {
                guard let shortcut = action.shortcut,
                      shortcut.hasChord,
                      let binding = ShortcutPrefixChordBinding(
                          actionID: action.id,
                          shortcut: shortcut.cmuxSettingsStoredShortcut,
                          label: action.title
                      ) else {
                    continue
                }
                result.append(binding)
            }
        }
        return result
    }

    private func windowID(for event: NSEvent) -> Int? {
        let number = owner?.prefixChordWindowNumber(
            for: event,
            fallbackWindow: owner?.resolvedShortcutEventWindow(event)
        ) ?? event.windowNumber
        return number > 0 ? number : nil
    }

    private func eventIdentity(
        for event: NSEvent,
        windowID: Int?
    ) -> ShortcutPrefixChordEventIdentity {
        ShortcutPrefixChordEventIdentity(
            eventNumber: 0,
            windowID: windowID,
            keyCode: event.keyCode,
            modifierFlags: event.modifierFlags.rawValue,
            timestamp: event.timestamp
        )
    }

    private func prefixStroke(from shortcut: StoredShortcut) -> CmuxSettings.ShortcutStroke? {
        guard let normalized = CmuxSettings.ShortcutPrefixPolicy().normalized(
            shortcut.cmuxSettingsStoredShortcut
        ), !normalized.isUnbound else {
            return nil
        }
        return normalized.first
    }
}
