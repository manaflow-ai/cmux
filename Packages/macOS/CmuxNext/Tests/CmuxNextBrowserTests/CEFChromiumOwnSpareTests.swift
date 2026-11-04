import Foundation
import Testing
@testable import CmuxNextBrowser

/// The browser process starts with Chromium's own spare renderer policy: no cmux spare switch on any
/// fork, and no switch that turns site isolation or content's spare off. This is the shipped default
/// (the `chromiumSpareAfterFirstTab` feature off) and pins it for that feature's removal
/// (prove-or-remove 11-04, row p13-06).
@Suite struct CEFChromiumOwnSpareTests {
    private func arguments(forkAPIVersion: Int32) -> [String] {
        CEFSwitches.current(forkAPIVersion: forkAPIVersion, bundleIdentifier: "com.cmuxterm.app.next", environment: [:]).arguments
    }

    @Test(arguments: [Int32(0), 27, 29])
    func noCmuxSpareSwitchReachesChromium(forkAPIVersion: Int32) {
        let arguments = arguments(forkAPIVersion: forkAPIVersion)
        #expect(!arguments.contains { $0.hasPrefix("cmux-spare-renderer") }, "\(arguments)")
    }

    /// The Chromium Host builds no spare window and relies on content's spare RenderProcessHost, which
    /// Chrome desktop keeps at all times only under site-per-process
    /// (`RenderProcessHostImpl::IsSpareProcessKeptAtAllTimes`).
    @Test func noSwitchTurnsContentsSpareRendererOff() {
        let arguments = arguments(forkAPIVersion: 29)
        let off: Set = ["single-process", "process-per-tab", "disable-site-isolation-trials", "disable-site-isolation-for-policy"]
        #expect(arguments.allSatisfy { argument in !off.contains(String(argument.prefix { $0 != "=" })) }, "\(arguments)")
        let disabled = arguments.filter { $0.hasPrefix("disable-features=") }.flatMap { $0.dropFirst("disable-features=".count).split(separator: ",") }
        #expect(!disabled.contains("SpareRendererForSitePerProcess") && !disabled.contains("SitePerProcess"), "\(arguments)")
    }
}
