import AppKit
import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextInput
import Testing

/// The UI pointer inspector on the app's input tap: with the picker closed it has no
/// subscription, whatever the Labs toggle; Inspect Element reads the click that opened its menu from
/// the tap's last pointer event; picking adds one modal-order intercept that consumes Escape and drops
/// it when it stops.
@MainActor @Suite(.serialized)
struct UIInspectorControllerTests {
    private func withPointerInspector(_ on: Bool, _ body: () throws -> Void) rethrows {
        _ = NSApplication.shared
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register([AgentPaneTunables.pointerInspector.descriptor])
        TunableStore.shared.set(AgentPaneTunables.pointerInspector.key, .bool(on))
        defer { TunableStore.shared.set(AgentPaneTunables.pointerInspector.key, nil) }
        try body()
    }

    /// Live subscriptions by stage and class, in a fixed order.
    private static func counts(_ tap: InputEventTap) -> [Int] {
        [InputEventTap.Stage.observe, .intercept, .afterDispatch].flatMap { stage in
            InputEventClass.allCases.map { tap.subscriberCount($0, stage: stage) }
        }
    }

    @Test func withTheLabsToggleOffTheInspectorHasNoSubscription() {
        withPointerInspector(false) {
            let tap = InputEventTap()
            let services = AppServices(environment: AppEnvironment.current([:]), inputTap: tap)
            let base = Self.counts(tap)
            let inspector = services.uiInspector
            #expect(Self.counts(tap) == base, "a closed inspector with the toggle off subscribed")
            inspector.toggle()
            #expect(!inspector.isPicking, "the picker opened with the toggle off")
            #expect(Self.counts(tap) == base)
        }
    }

    @Test func withTheLabsToggleOnTheClosedInspectorHasNoSubscription() {
        withPointerInspector(true) {
            let tap = InputEventTap()
            let services = AppServices(environment: AppEnvironment.current([:]), inputTap: tap)
            let base = Self.counts(tap)
            let inspector = services.uiInspector
            #expect(!inspector.isPicking)
            #expect(Self.counts(tap) == base, "a closed inspector with the toggle on subscribed")
        }
    }

    @Test func onlyARightClickOrControlClickOpensTheContextMenuInspected() {
        func record(_ type: InputEventType, window: Int = 7, modifiers: InputModifierFlags = []) -> InputEventRecord {
            InputEventRecord(type: type, timestamp: 1, windowNumber: window, ownerWindowNumber: window,
                             screenLocation: InputPoint(x: 40, y: 60), modifierFlags: modifiers)
        }
        let right = UIInspectorController.contextClick(record(.rightMouseDown))
        #expect(right?.point == NSPoint(x: 40, y: 60))
        #expect(right?.windowNumber == 7)
        #expect(UIInspectorController.contextClick(record(.leftMouseDown, modifiers: .control))?.windowNumber == 7,
                "a control-click opens the context menu")
        #expect(UIInspectorController.contextClick(record(.leftMouseDown)) == nil, "a plain click opens no context menu")
        #expect(UIInspectorController.contextClick(record(.mouseMoved)) == nil, "a move after the click is not the click")
        #expect(UIInspectorController.contextClick(record(.rightMouseDown, window: 0)) == nil, "a click in no window")
        #expect(UIInspectorController.contextClick(nil) == nil)
    }

    @Test func pickingAddsOneInterceptThatEscapeConsumesAndRemoves() throws {
        try withPointerInspector(true) {
            let tap = InputEventTap()
            let services = AppServices(environment: AppEnvironment.current([:]), inputTap: tap)
            let inspector = services.uiInspector
            let closed = Self.counts(tap)
            let intercepts = InputEventClass.allCases.map { tap.subscriberCount($0, stage: .intercept) }

            inspector.toggle()
            #expect(inspector.isPicking)
            for eventClass in InputEventClass.allCases {
                let added = [.pointerMove, .button, .key].contains(eventClass) ? 1 : 0
                #expect(tap.subscriberCount(eventClass, stage: .intercept) == intercepts[Int(eventClass.rawValue)] + added,
                        "\(eventClass) intercepts while picking")
            }

            let escapeUp = try Self.escape(.keyUp), escapeDown = try Self.escape(.keyDown)
            #expect(Self.deliverIntercepts(escapeUp, through: tap) == .pass, "a key-up is not the picker's")
            #expect(inspector.isPicking)
            #expect(Self.deliverIntercepts(escapeDown, through: tap) == .consume, "Escape reached AppKit")
            #expect(!inspector.isPicking, "Escape did not stop the picker")
            #expect(Self.counts(tap) == closed, "the stopped picker kept its intercept")
        }
    }

    // MARK: helpers

    /// Drives one event through the tap the way `CmuxApplication.sendEvent` does; returns the intercepts' result.
    private static func deliverIntercepts(_ event: NSEvent, through tap: InputEventTap) -> InputEventTap.InterceptResult {
        var result = InputEventTap.InterceptResult.pass
        tap.dispatching {
            tap.deliverObserve(event)
            result = tap.deliverIntercepts(event)
            tap.deliverAfterDispatch(event)
        }
        return result
    }

    private static func escape(_ type: NSEvent.EventType) throws -> NSEvent {
        _ = NSApplication.shared
        return try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 1, windowNumber: 0,
                                             context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                             isARepeat: false, keyCode: 53))
    }
}
