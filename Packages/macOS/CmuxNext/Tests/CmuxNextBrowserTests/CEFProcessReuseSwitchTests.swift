import Foundation
import Testing
@testable import CmuxNextBrowser

/// p07-memory-046: Chrome shares a renderer between at most 2 same-site main frames below its
/// process limit, and Chromium 154 stops that for the whole browser once any frame had a DevTools
/// agent (an agent's CDP session is one). The fork's switch keeps the check per renderer; the app
/// passes it exactly when the running fork and shim have the renderer paths (fork API 29), the
/// same decision the runtime makes for its tabs (`CEFRuntime` builds both from `CEFForkFeatures`).
@Suite struct CEFProcessReuseSwitchTests {
    struct Row: Sendable, CustomTestStringConvertible {
        let forkAPI: Int32
        let shimExports: Bool
        let passes: Bool
        var testDescription: String { "fork API \(forkAPI), shim exports \(shimExports)" }
    }

    @Test(arguments: [
        Row(forkAPI: 0, shimExports: false, passes: false),
        Row(forkAPI: 24, shimExports: true, passes: false),
        Row(forkAPI: 28, shimExports: true, passes: false),
        Row(forkAPI: 29, shimExports: false, passes: false),
        Row(forkAPI: 29, shimExports: true, passes: true),
        Row(forkAPI: 32, shimExports: true, passes: true),
    ])
    func theReuseSwitchFollowsTheRendererPaths(row: Row) {
        let features = CEFForkFeatures(forkAPIVersion: row.forkAPI, shimHasRendererPaths: row.shimExports)
        let arguments = CEFSwitches.current(forkAPIVersion: row.forkAPI, rendererPaths: features.rendererPaths,
                                            bundleIdentifier: "com.cmuxterm.app.next", environment: [:]).arguments
        #expect(arguments.filter { $0 == CEFSwitches.processReusePerRendererDevTools }.count == (row.passes ? 1 : 0),
                "\(arguments)")
    }

    /// The switch is a bare name: a value or a feature-list entry would be a different switch to the fork.
    @Test func theSwitchIsTheForksName() {
        #expect(CEFSwitches.processReusePerRendererDevTools == "cmux-process-reuse-per-renderer-devtools")
        #expect(CEFForkFeatures.rendererPathsForkAPI == 29)
    }
}
