@testable import CmuxNextBrowser
import Foundation
import Testing

/// p09-observability-106: Chromium's HangWatcher runs only in the browser process, and only once the fork took cmux's
/// dump handler (`--cmux-browser-hang-watch`); every child process keeps `EnableHangWatcher` and
/// `EnableHangWatcherOnGpuProcess` off, because children take the browser's feature list.
@Suite struct CEFHangWatcherSwitchTests {
    private static func arguments(browserHangWatch: Bool) -> [String] {
        CEFSwitches.current(forkAPIVersion: CEFForkFeatures.hangDumpForkAPI, browserHangWatch: browserHangWatch,
                            bundleIdentifier: "com.cmuxterm.app.next", environment: [:]).arguments
    }

    /// Every entry of every `disable-features=` switch: the shim merges them into one list.
    private static func disabledFeatures(_ arguments: [String]) -> Set<String> {
        let prefix = "disable-features="
        return Set(arguments.filter { $0.hasPrefix(prefix) }
            .flatMap { $0.dropFirst(prefix.count).split(separator: ",").map(String.init) })
    }

    @Test func theBrowserWatchesOnlyWithTheHandlerAndChildrenNever() {
        let watching = Self.arguments(browserHangWatch: true)
        #expect(watching.filter { $0 == CEFSwitches.browserHangWatchSwitch }.count == 1)
        #expect(Self.disabledFeatures(watching).isSuperset(of: CEFSwitches.hangWatcherOffFeatures),
                "children read the features, so the watcher stays off in every child")
        #expect(!watching.contains { $0.hasPrefix("enable-features=") && $0.contains("EnableHangWatcher") })
        let off = Self.arguments(browserHangWatch: false)
        #expect(!off.contains { $0.hasPrefix(CEFSwitches.browserHangWatchSwitch) })
        #expect(Self.disabledFeatures(off).isSuperset(of: CEFSwitches.hangWatcherOffFeatures))
    }

    @Test func anAppFeatureCannotTurnTheChildWatcherBackOn() {
        let switches = CEFSwitches.current(forkAPIVersion: CEFForkFeatures.hangDumpForkAPI, chromiumFeatures: ["EnableHangWatcher"],
                                           browserHangWatch: true, bundleIdentifier: "com.cmuxterm.app.next", environment: [:])
        #expect(!switches.enabledFeatures.contains("EnableHangWatcher"), "disable wins, as in FeatureList::InitFromCommandLine")
    }

    @Test func theHangDumpGateNeedsTheShimExportAndTheForksAPI() {
        let below = CEFForkFeatures(forkAPIVersion: CEFForkFeatures.hangDumpForkAPI - 1, shimHasRendererPaths: true, shimHasHangDump: true)
        let noExport = CEFForkFeatures(forkAPIVersion: CEFForkFeatures.hangDumpForkAPI, shimHasRendererPaths: true)
        let both = CEFForkFeatures(forkAPIVersion: CEFForkFeatures.hangDumpForkAPI, shimHasRendererPaths: false, shimHasHangDump: true)
        #expect(!below.hangDumps && !noExport.hangDumps && both.hangDumps)
    }
}
