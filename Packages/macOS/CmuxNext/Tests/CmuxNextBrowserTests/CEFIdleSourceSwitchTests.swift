import Foundation
import Testing
@testable import CmuxNextBrowser

/// Q8 idle sources quieted by a Chromium feature. PartitionAlloc's memory reclaimer ran on
/// the main thread of every Chromium process every 4 s, the app's CrBrowserMain included;
/// `PartitionAllocAdaptiveMemoryReclaimInterval` backs it off to 1 min while there is little to decommit.
@Suite struct CEFIdleSourceSwitchTests {
    static let reclaimBackOff = "PartitionAllocAdaptiveMemoryReclaimInterval"

    @Test(arguments: CEFSwitchesWakeUpAlignmentTests.forkAPIs)
    func everyForkBacksOffTheMemoryReclaimer(forkAPIVersion: Int32) {
        for bundle in ["com.cmuxterm.app.next", "com.cmuxterm.app.debug.tag"] {
            let arguments = CEFSwitchesWakeUpAlignmentTests.arguments(forkAPIVersion: forkAPIVersion, bundle: bundle)
            #expect(arguments.filter { $0.hasPrefix("enable-features=") }.count == 1, "\(arguments)")
            let features = CEFSwitchesWakeUpAlignmentTests.enabledFeatures(arguments)
            #expect(features.filter { $0 == Self.reclaimBackOff }.count == 1, "fork API \(forkAPIVersion): \(features)")
            // A pinned `PartitionAllocMemoryReclaimer:interval` would override the adaptive interval
            // (MemoryReclaimerSupport::GetInterval), and disabling the reclaimer would keep memory it should return.
            #expect(!arguments.contains { $0.contains("PartitionAllocMemoryReclaimer") }, "\(arguments)")
        }
    }

    /// The app's own Chromium features may name it too; it still appears once.
    @Test func anAppFeatureNamingItKeepsOneEntry() {
        let arguments = CEFSwitchesWakeUpAlignmentTests.arguments(forkAPIVersion: 29, chromiumFeatures: [Self.reclaimBackOff])
        let features = CEFSwitchesWakeUpAlignmentTests.enabledFeatures(arguments)
        #expect(features.filter { $0 == Self.reclaimBackOff }.count == 1, "\(features)")
        #expect(!arguments.contains { $0.hasPrefix("disable-features=") && $0.contains(Self.reclaimBackOff) })
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    /// The Chromium Host takes the same switch set, so its processes back off too.
    @Test func theChromiumHostBacksOffToo() {
        let root = URL(filePath: "/tmp/cmux-cef-idle-source-test", directoryHint: .isDirectory)
        let layout = CEFRuntimeLayout(frameworksDirectory: root, mainBundle: root, helperApp: root)
        let hostSwitches = ChromiumHostConfiguration.arguments(
            layout: layout, rootCache: root, bundleIdentifier: "com.cmuxterm.app.next", environment: [:])
            .filter { $0.hasPrefix("--cef-switch=") }
            .map { String($0.dropFirst("--cef-switch=".count)) }
        #expect(CEFSwitchesWakeUpAlignmentTests.enabledFeatures(hostSwitches).contains(Self.reclaimBackOff), "\(hostSwitches)")
    }
    #endif
}
