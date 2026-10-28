@testable import CmuxNextBrowser
import Foundation
import Testing

/// Chrome runtime services that cmux does not use stay off at Home: sync, the
/// HangWatcher thread in every Chromium process and the Optimization Hints component. Safe Browsing
/// and the component updater (Widevine CDM, CRLSet) are a written decision to keep (perf-lead.md
/// "Chrome runtime idle services"), so no switch may turn them off.
@Suite struct CEFIdleServicesSwitchTests {
    private static func arguments(bundle: String = "com.cmuxterm.app.next") -> [String] {
        CEFSwitches.current(forkAPIVersion: CEFSwitches.resizeSyncForkAPI, bundleIdentifier: bundle, environment: [:]).arguments
    }

    /// Every entry of every `disable-features=` switch: the shim merges them into one list.
    private static func disabledFeatures(_ arguments: [String]) -> Set<String> {
        let prefix = "disable-features="
        return Set(arguments.filter { $0.hasPrefix(prefix) }
            .flatMap { $0.dropFirst(prefix.count).split(separator: ",").map(String.init) })
    }

    @Test(arguments: ["com.cmuxterm.app.next", "com.cmuxterm.app.debug.tag"])
    func theBrowserProcessStartsWithTheUnusedServicesOff(bundle: String) {
        let arguments = Self.arguments(bundle: bundle)
        #expect(arguments.contains("disable-sync"))
        let disabled = Self.disabledFeatures(arguments)
        #expect(disabled.isSuperset(of: ["EnableHangWatcher", "EnableHangWatcherOnGpuProcess", "OptimizationHints"]))
    }

    @Test func safeBrowsingTheComponentUpdaterAndCastStayOn() {
        let arguments = Self.arguments()
        for kept in ["disable-component-update", "disable-background-networking", "safebrowsing-disable-auto-update",
                     "disable-client-side-phishing-detection"] {
            #expect(!arguments.contains(kept), "\(kept) would turn off a service perf-lead.md keeps")
        }
        let disabled = Self.disabledFeatures(arguments)
        for kept in ["SafeBrowsing", "OptimizationTargetPrediction", "MediaRouter", "NetworkTimeServiceQuerying"] {
            #expect(!disabled.contains(kept), "\(kept) is kept on (perf-lead.md \"Chrome runtime idle services\")")
        }
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    /// The Chromium Host takes the same switch set, so a host-run Chromium has the same services off.
    @Test func theChromiumHostGetsTheSameSwitches() {
        let root = URL(filePath: "/nonexistent/cmux-idle-services")
        let layout = CEFRuntimeLayout(frameworksDirectory: root, mainBundle: root, helperApp: root)
        let host = ChromiumHostConfiguration.arguments(layout: layout, rootCache: root, bundleIdentifier: "com.cmuxterm.app.next",
                                                       environment: [:])
        #expect(host.contains("--cef-switch=disable-sync"))
        let prefix = "--cef-switch="
        let disabled = Self.disabledFeatures(host.compactMap { $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : nil })
        #expect(disabled.isSuperset(of: ["EnableHangWatcher", "EnableHangWatcherOnGpuProcess", "OptimizationHints"]))
    }
    #endif
}
