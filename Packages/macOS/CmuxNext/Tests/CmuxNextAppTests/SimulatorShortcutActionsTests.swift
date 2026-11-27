import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextFocus
import Testing

/// The phone tab's keyboard shortcuts (Simulator: Home, Rotate Left/Right, Toggle Appearance,
/// Toggle Software Keyboard). A focused phone tab publishes `simulatorFocused`, so their keys
/// (Shift-Cmd-H, Cmd-Left/Right, Shift-Cmd-A, Shift-Cmd-K) reach them there and nowhere else.
@MainActor @Suite(.serialized)
struct SimulatorShortcutActionsTests {
    nonisolated static let ids: [String] = ["simulatorHome", "simulatorRotateLeft", "simulatorRotateRight",
                                "simulatorToggleAppearance", "simulatorToggleSoftwareKeyboard"]

    static func services() -> AppServices {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        return services
    }

    @Test func aFocusedPhoneTabIsSimulatorFocused() {
        var focus = FocusState()
        focus.resolved = .page(pane: "pane_a", tab: "local-page:phone:A1B2")
        let context = KeyRouter.keyContext(for: focus, appContext: [], facts: KeyFacts(internalPage: "phone"))
        #expect(context.bits.contains(.simulatorFocused))
    }

    @Test func anotherPageOrATerminalIsNotSimulatorFocused() {
        var page = FocusState()
        page.resolved = .page(pane: "pane_a", tab: "local-page:files-pane:A1B2")
        #expect(!KeyRouter.keyContext(for: page, appContext: [], facts: KeyFacts(internalPage: "files-pane")).bits.contains(.simulatorFocused))
        var terminal = FocusState()
        terminal.resolved = .terminal(pane: "pane_a", tab: "tab_a")
        terminal.context.terminal = true
        let context = KeyRouter.keyContext(for: terminal, appContext: [.simulatorFocused], facts: KeyFacts())
        #expect(!context.bits.contains(.simulatorFocused), "a stale app-wide simulatorFocused leaked into a terminal's keys")
    }

    @Test(arguments: ids)
    func eachShortcutIsAWorkingAction(id: String) {
        let services = Self.services()
        #expect(services.registry.unavailableReason(for: ActionID(rawValue: id)) == nil)
    }

    @Test(arguments: ids)
    func withNoPhoneTabTheShortcutSaysSo(id: String) {
        let services = Self.services()
        services.registry.context.insert(.simulatorFocused)
        let reason = services.registry.capturingRefusal {
            _ = services.registry.perform(ActionID(rawValue: id), invocation: ActionInvocation(origin: .cli))
        }
        #expect(reason == MiscHandlerStrings.noPhoneTab)
    }
}
