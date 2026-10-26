import AppKit
import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextInput
import Testing

/// The UI pointer inspector on the app's input tap (p04-input-016): with the Labs toggle off it has no
/// subscription; with it on and the picker closed it only observes right clicks (the context-menu
/// point); picking adds one modal-order intercept that consumes Escape and drops it when it stops.
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

    @Test func pickingAddsOneInterceptThatEscapeConsumesAndRemoves() throws {
        try withPointerInspector(true) {
            let tap = InputEventTap()
            let services = AppServices(environment: AppEnvironment.current([:]), inputTap: tap)
            let observeButtons = tap.subscriberCount(.button, stage: .observe)
            let intercepts = InputEventClass.allCases.map { tap.subscriberCount($0, stage: .intercept) }
            let inspector = services.uiInspector
            #expect(tap.subscriberCount(.button, stage: .observe) == observeButtons + 1, "the context-click observer is missing")
            #expect(InputEventClass.allCases.map { tap.subscriberCount($0, stage: .intercept) } == intercepts,
                    "the closed picker intercepts input")
            let closed = Self.counts(tap)

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
