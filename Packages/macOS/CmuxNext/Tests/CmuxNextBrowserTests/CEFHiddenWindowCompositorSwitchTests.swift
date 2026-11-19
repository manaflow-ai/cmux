import Foundation
import Testing
@testable import CmuxNextBrowser

/// Goal memory-per-chat (Leo: "Each open chat costs at most 1.2x an empty chat in memory"; 2026-11-17: "instant >
/// memory"). A hidden but kept chat page's window is hidden by the fork, and on macOS Chromium 157 that only suspends
/// the window's compositor: Viz kept its display buffers, part of the ~32 MB of GPU memory each extra page cost at
/// 10 chats. The browser process starts with `NotifyCompositorOfWindowVisibilityOnMacOs`, so a hidden window's
/// compositor turns invisible and Viz gives its backbuffers back, while the page and its last frame stay.
@Suite struct CEFHiddenWindowCompositorSwitchTests {
    @Test(arguments: [0, 7, 27, 29, 35])
    func hiddenPageWindowsReleaseTheirCompositorBuffers(forkAPIVersion: Int32) {
        let switches = CEFSwitches.current(forkAPIVersion: forkAPIVersion, bundleIdentifier: "com.cmuxterm.app.next", environment: [:])
        #expect(switches.arguments.contains("enable-features=NotifyCompositorOfWindowVisibilityOnMacOs"))
    }

    /// The staged update's pre-warm starts Chromium with the same feature list.
    @Test func stagedPrewarmHasIt() {
        let switches = CEFStagedPrewarm.switches(forkAPIVersion: 35, rendererPaths: true, bundleIdentifier: "com.cmuxterm.app.next")
        #expect(switches.filter { $0 == "enable-features=NotifyCompositorOfWindowVisibilityOnMacOs" }.count == 1)
    }
}
