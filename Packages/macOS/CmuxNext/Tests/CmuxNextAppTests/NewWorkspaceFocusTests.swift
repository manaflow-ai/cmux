import CmuxNextActions
import Testing
@testable import CmuxNextApp

/// Only a run that asks to activate the app does: `cmux open <dir>` run by a
/// person sends `activate`. Other `workspace.create` callers that pass
/// `focus: true` without checking who runs them (the local tmux attach,
/// run by agents too) select the workspace in its window but never take
/// the Mac's focus.
@Suite struct NewWorkspaceFocusTests {
    private func focus(_ arguments: [String: ActionValue], origin: ActionOrigin = .cli) -> NewWorkspaceFocus {
        NewWorkspaceFocus(ActionInvocation(arguments: arguments, origin: origin))
    }

    /// Regression: a non-interactive local tmux attach (`focus: true`, no
    /// `activate`) activated the app.
    @Test func aFocusedCreateWithoutActivateDoesNotActivateTheApp() {
        #expect(focus(["focus": .bool(true)]) == NewWorkspaceFocus(shows: true, activatesApp: false))
    }

    @Test func anInteractiveOpenActivatesTheApp() {
        #expect(focus(["focus": .bool(true), "activate": .bool(true)]) == NewWorkspaceFocus(shows: true, activatesApp: true))
    }

    @Test func aBackgroundCreateNeitherShowsNorActivates() {
        #expect(focus(["focus": .bool(false)]) == NewWorkspaceFocus(shows: false, activatesApp: false))
        #expect(focus(["focus": .bool(false), "activate": .bool(true)]) == NewWorkspaceFocus(shows: false, activatesApp: false))
    }

    /// Cmd-N, the menu and the palette show it; the window is already key.
    @Test func anInAppCreateShowsWithoutActivating() {
        #expect(focus([:], origin: .user) == NewWorkspaceFocus(shows: true, activatesApp: false))
    }
}
