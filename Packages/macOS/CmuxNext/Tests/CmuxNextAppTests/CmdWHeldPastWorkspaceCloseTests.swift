import CmuxNextFocus
@testable import CmuxNextApp
import Foundation
import Testing

/// A held Cmd-W that closed its workspace (its last tab: CmdWLastTabClosesWorkspaceTests) closes nothing more while the
/// key stays held: the window shows another workspace now, whose tabs the held key never aimed at (handoff/
/// motion-cascade.md rule 6). A new key press, a click or a menu run closes as usual.
@MainActor @Suite(.serialized)
struct CmdWHeldPastWorkspaceCloseTests {
    @Test func repeatsOfTheKeyThatClosedAWorkspaceCloseNothingUntilANewPress() throws {
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"w1","workspace_key":"w1"}"#.utf8))
        let window = WindowState(record: record), other = WindowState(record: record)
        let press = PaneCloseAim.Press(time: 1, isKey: true, isRepeat: false)
        #expect(!TabCloseGuard.repeatsPastWorkspaceClose(press, in: window))
        TabCloseGuard.noteWorkspaceClosed(by: press, in: window)
        let held = PaneCloseAim.Press(time: 1.05, isKey: true, isRepeat: true)
        #expect(TabCloseGuard.repeatsPastWorkspaceClose(held, in: window), "a repeat of the held key closed a tab in the next workspace")
        #expect(TabCloseGuard.repeatsPastWorkspaceClose(held, in: window))
        #expect(!TabCloseGuard.repeatsPastWorkspaceClose(held, in: other), "another window's held key was refused")
        let click = PaneCloseAim.Press(time: 1.1, isKey: false, isRepeat: false)
        #expect(!TabCloseGuard.repeatsPastWorkspaceClose(click, in: window), "a click was refused")
        let next = PaneCloseAim.Press(time: 2, isKey: true, isRepeat: false)
        #expect(!TabCloseGuard.repeatsPastWorkspaceClose(next, in: window), "a new key press was refused")
        #expect(!TabCloseGuard.repeatsPastWorkspaceClose(PaneCloseAim.Press(time: 2.05, isKey: true, isRepeat: true), in: window),
                "the new press's own repeats were refused")
    }
}
