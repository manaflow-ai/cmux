@testable import CmuxNextBrowser
import Foundation
import Testing

/// The Chromium Host relies on content's spare RenderProcessHost for a fast first tab
/// (CEFSpareRenderer): no switch cmux gives Chromium may turn it off.
@Suite struct CEFSpareRendererTests {
    private static let layout = CEFRuntimeLayout(
        frameworksDirectory: URL(filePath: "/Applications/cmux.app/Contents/Frameworks"),
        mainBundle: URL(filePath: "/Applications/cmux.app"),
        helperApp: URL(filePath: "/Applications/cmux.app/Contents/Frameworks/cmux Helper.app"))

    /// The host's Chromium switches, without the `--cef-switch=` prefix.
    private static func hostSwitches(bundleIdentifier: String?) -> [String] {
        let prefix = "--cef-switch="
        return ChromiumHostConfiguration.arguments(layout: layout, rootCache: URL(filePath: "/tmp/chromium-host"),
                                                   bundleIdentifier: bundleIdentifier, environment: [:])
            .filter { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }
    }

    @Test(arguments: ["com.cmuxterm.app", "com.cmuxterm.app.debug", nil] as [String?])
    func theHostKeepsTheSpareRenderer(bundleIdentifier: String?) {
        let switches = Self.hostSwitches(bundleIdentifier: bundleIdentifier)
        #expect(!switches.isEmpty)
        #expect(CEFSpareRenderer.blockers(in: switches).isEmpty)
    }

    @Test func theInProcessSwitchesKeepTheSpareRenderer() {
        let switches = CEFSwitches.current(forkAPIVersion: CEFSwitches.resizeSyncForkAPI, rendererPaths: true,
                                           bundleIdentifier: "com.cmuxterm.app", environment: [:],
                                           keepsUnpackedEnabled: true).arguments
        #expect(CEFSpareRenderer.blockers(in: switches).isEmpty)
    }

    @Test func switchesThatTurnItOff() {
        let blocking = ["single-process", "disable-site-isolation-trials", "renderer-process-limit=2",
                        "disable-features=Foo, SpareRendererForSitePerProcess"]
        #expect(CEFSpareRenderer.blockers(in: blocking + ["no-first-run"]) == blocking)
    }

    @Test func otherFeatureListsDoNot() {
        let switches = ["disable-features=MacAppCodeSignClone,SpareRendererForSitePerProcessX",
                        "enable-features=SpareRendererForSitePerProcess", "site-per-process"]
        #expect(CEFSpareRenderer.blockers(in: switches).isEmpty)
    }
}
