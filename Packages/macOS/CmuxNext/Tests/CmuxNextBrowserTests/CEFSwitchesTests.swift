import CmuxNextCompat
import Foundation
import Testing
@testable import CmuxNextBrowser

/// Bench builds replay recorded pages with Web Page Replay (p12-perf-process task 221): the browser
/// process takes `host-resolver-rules` and `ignore-certificate-errors-spki-list` from
/// `CMUX_NEXT_BENCH_CEF_SWITCHES`, for a development or bench bundle, and nothing else from it.
@Suite struct CEFSwitchesTests {
    /// The rules Web Page Replay's README passes: ports and commas inside the value.
    static let rules = "host-resolver-rules=MAP *:80 127.0.0.1:8080,MAP *:443 127.0.0.1:8081,EXCLUDE localhost"
    static let spki = "ignore-certificate-errors-spki-list=PhrPvGIaAMmd29hj8BCZOq096yj7uMpRNHpn5PDxI6I="

    private func switches(bundle: String, bench: String, extra: [String: String] = [:]) -> [String] {
        CEFSwitches.current(forkAPIVersion: 29, bundleIdentifier: bundle,
                            environment: extra.merging(["CMUX_NEXT_BENCH_CEF_SWITCHES": bench]) { _, new in new }).arguments
    }

    @Test(arguments: ["com.cmuxterm.app.debug.bench-tag", "com.cmuxterm.app.next.dev"])
    func aBenchBundleTakesTheReplaySwitches(bundle: String) {
        let arguments = switches(bundle: bundle, bench: "--\(Self.rules)\n\(Self.spki)\n")
        #expect(arguments.contains(Self.rules))
        #expect(arguments.contains(Self.spki))
    }

    @Test func theBenchPathDropsEveryOtherSwitch() {
        let bench = [
            Self.rules,
            "remote-debugging-port=9222",
            "enable-features=BackForwardCache",
            "disable-gpu",
            "no-sandbox=1",
            "host-resolver-rules=",
            "ignore-certificate-errors-spki-list",
        ].joined(separator: "\n")
        #expect(CEFSwitches.benchSwitches(bench) == [Self.rules])
        let arguments = switches(bundle: "com.cmuxterm.app.debug.bench-tag", bench: bench)
        #expect(!arguments.contains("remote-debugging-port=9222"))
        #expect(!arguments.contains("enable-features=BackForwardCache"))
        #expect(!arguments.contains("disable-gpu"))
        #expect(!arguments.contains { $0.hasPrefix("no-sandbox") })
        #expect(arguments.filter { $0.hasPrefix("host-resolver-rules") } == [Self.rules])
    }

    /// A shipped bundle id never takes them, also not with the mock keychain variable a CI run sets.
    @Test(arguments: ["com.cmuxterm.app", "com.cmuxterm.app.nightly.cmux-next", "com.cmuxterm.app.next"])
    func aShippedBundleIgnoresTheVariable(bundle: String) {
        let arguments = switches(bundle: bundle, bench: "\(Self.rules)\n\(Self.spki)", extra: ["CMUX_MOCK_KEYCHAIN": "1"])
        #expect(!arguments.contains { $0.hasPrefix("host-resolver-rules") || $0.hasPrefix("ignore-certificate-errors-spki-list") })
    }

    /// The bench list is newline-separated: the diagnostic list's colon would cut the rules apart.
    @Test func aColonInsideAValueStaysInTheSwitch() {
        #expect(CEFSwitches.benchSwitches(Self.rules) == [Self.rules])
        #expect(CEFSwitches.benchSwitches(nil).isEmpty)
        #expect(CEFSwitches.benchSwitches("\r\n\(Self.spki)\r\n") == [Self.spki])
    }
}

/// chromium-host-bench.py `--modes tcc` measures Chromium's real "Chromium Safe Storage" read on a
/// bench build, whose development bundle id otherwise runs Chromium with its mock keychain.
@Suite struct CEFSwitchesBenchKeychainTests {
    private func arguments(bundle: String, environment: [String: String] = [:]) -> [String] {
        CEFSwitches.current(forkAPIVersion: 29, bundleIdentifier: bundle, environment: environment).arguments
    }

    @Test(arguments: ["com.cmuxterm.app.debug.bench-tag", "com.cmuxterm.app.next.dev"])
    func aDevelopmentBundleUsesTheMockKeychain(bundle: String) {
        #expect(arguments(bundle: bundle).contains("use-mock-keychain"))
    }

    @Test(arguments: ["com.cmuxterm.app.debug.bench-tag", "com.cmuxterm.app.next.dev"])
    func theBenchSwitchGivesADevelopmentBundleTheRealKeychain(bundle: String) {
        #expect(!arguments(bundle: bundle, environment: ["CMUX_NEXT_BENCH_REAL_KEYCHAIN": "1"]).contains("use-mock-keychain"))
        #expect(arguments(bundle: bundle, environment: ["CMUX_NEXT_BENCH_REAL_KEYCHAIN": "0"]).contains("use-mock-keychain"))
    }

    @Test func theMockKeychainVariableStillWins() {
        let environment = ["CMUX_NEXT_BENCH_REAL_KEYCHAIN": "1", "CMUX_MOCK_KEYCHAIN": "1"]
        #expect(arguments(bundle: "com.cmuxterm.app.debug.bench-tag", environment: environment).contains("use-mock-keychain"))
    }

    @Test(arguments: ["com.cmuxterm.app", "com.cmuxterm.app.nightly.cmux-next", "com.cmuxterm.app.next"])
    func aShippedBundleKeepsTheRealKeychain(bundle: String) {
        #expect(!arguments(bundle: bundle).contains("use-mock-keychain"))
        #expect(!arguments(bundle: bundle, environment: ["CMUX_NEXT_BENCH_REAL_KEYCHAIN": "1"]).contains("use-mock-keychain"))
    }
}

/// Chromium's wake-up alignment. `AlignWakeUps` snaps each delayed wake-up of every
/// Chromium thread to one 8 ms grid (MessagePump::AdjustDelayedRunTime), and `BatterySaverModeAlignWakeUps`
/// lets battery saver widen it to 32 ms in child processes. Both are `FEATURE_DISABLED_BY_DEFAULT`, and
/// Chrome turns them on only through field trials, which `disable-field-trial-config` leaves off, so cmux
/// names them. `TimerSlackMac` stays the default-off feature `cefTimerSlack`.
@Suite struct CEFSwitchesWakeUpAlignmentTests {
    /// Every fork API from stock CEF past the newest the app knows today.
    nonisolated static let forkAPIs = Array(Int32(0)...40)

    static func arguments(forkAPIVersion: Int32, chromiumFeatures: [String] = [],
                          bundle: String = "com.cmuxterm.app.next") -> [String] {
        let fork = CEFForkFeatures(forkAPIVersion: forkAPIVersion, shimHasRendererPaths: true)
        return CEFSwitches.current(forkAPIVersion: forkAPIVersion, rendererPaths: fork.rendererPaths,
                                   chromiumFeatures: chromiumFeatures, bundleIdentifier: bundle, environment: [:],
                                   keepsUnpackedEnabled: true).arguments
    }

    /// The features of every `enable-features` entry of `arguments`, in order.
    static func enabledFeatures(_ arguments: [String]) -> [String] {
        arguments
            .filter { $0.hasPrefix("enable-features=") }
            .flatMap { $0.dropFirst("enable-features=".count).split(separator: ",").map(String.init) }
    }

    @Test(arguments: forkAPIs)
    func chromiumAlignsItsWakeUps(forkAPIVersion: Int32) {
        let features = Self.enabledFeatures(Self.arguments(forkAPIVersion: forkAPIVersion))
        #expect(features.contains("AlignWakeUps"), "fork API \(forkAPIVersion)")
        #expect(features.contains("BatterySaverModeAlignWakeUps"), "fork API \(forkAPIVersion)")
    }

    /// One entry, also with the app's own Chromium features, each feature once: a second entry for a
    /// feature already listed would lose, and duplicate parameters fail a DCHECK (the IPH note in
    /// ``CEFSwitches/chromePromptOffSwitches``).
    @Test(arguments: forkAPIs, [[], ["TimerSlackMac"], ["AlignWakeUps", CEFSwitches.chromePromptOffFeature]])
    func everyEnabledFeatureIsInOneEntry(forkAPIVersion: Int32, chromiumFeatures: [String]) {
        for bundle in ["com.cmuxterm.app.next", "com.cmuxterm.app.debug.tag"] {
            let arguments = Self.arguments(forkAPIVersion: forkAPIVersion, chromiumFeatures: chromiumFeatures, bundle: bundle)
            #expect(arguments.filter { $0.hasPrefix("enable-features=") }.count == 1, "\(arguments)")
            let features = Self.enabledFeatures(arguments)
            #expect(Set(features).count == features.count, "\(features)")
            #expect(features.contains(CEFSwitches.chromePromptOffFeature))
            #expect(Set(chromiumFeatures).isSubset(of: features))
            #expect(features.contains("AsyncLiveResize") == (forkAPIVersion < CEFSwitches.resizeSyncForkAPI))
        }
    }

    /// `TimerSlackMac` trades the snap for kernel timer tolerance; only the default-off feature
    /// `cefTimerSlack` turns it on, on no fork API by itself.
    @Test(arguments: forkAPIs)
    func noForkAPITurnsOnTimerSlackByItself(forkAPIVersion: Int32) {
        #expect(!Self.arguments(forkAPIVersion: forkAPIVersion).contains { $0.contains("TimerSlackMac") })
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    /// The Chromium Host takes the same switch set, so its browser process and children align too.
    @Test func theChromiumHostAlignsItsWakeUpsToo() {
        let root = URL(filePath: "/tmp/cmux-cef-switches-test", directoryHint: .isDirectory)
        let layout = CEFRuntimeLayout(frameworksDirectory: root, mainBundle: root, helperApp: root)
        let hostSwitches = ChromiumHostConfiguration.arguments(
            layout: layout, rootCache: root, bundleIdentifier: "com.cmuxterm.app.next", environment: [:])
            .filter { $0.hasPrefix("--cef-switch=") }
            .map { String($0.dropFirst("--cef-switch=".count)) }
        #expect(hostSwitches.filter { $0.hasPrefix("enable-features=") }.count == 1, "\(hostSwitches)")
        #expect(Set(CEFSwitches.wakeUpAlignmentFeatures).isSubset(of: Self.enabledFeatures(hostSwitches)))
    }
    #endif
}

/// The app's `process: chromium` features reach CEF as one `enable-features` and one
/// `disable-features` entry. A feature the app turns off is only on the disable list, also when the enable
/// list names it too or cmux names it itself: disable wins, as Chromium's FeatureList::InitFromCommandLine
/// processes the disabled features first (base/feature_list.cc).
@Suite struct CEFSwitchesChromiumFeatureTests {
    private func switches(enabled: [String], disabled: [String], forkAPIVersion: Int32 = 29) -> [String] {
        CEFSwitches.current(forkAPIVersion: forkAPIVersion, chromiumFeatures: enabled, disabledChromiumFeatures: disabled,
                            bundleIdentifier: "com.cmuxterm.app.next", environment: [:]).arguments
    }

    private func features(_ arguments: [String], _ prefix: String) -> [String] {
        arguments.filter { $0.hasPrefix(prefix) }.flatMap { $0.dropFirst(prefix.count).split(separator: ",").map(String.init) }
    }

    /// A remote off reaches the switches as an off feature: on the disable list, not on the enable list.
    @Test func anOffFeatureIsOnlyDisabled() {
        let arguments = switches(enabled: [], disabled: ["BackForwardCache"])
        #expect(features(arguments, "disable-features=") == CEFSwitches.idleServiceOffFeatures + ["BackForwardCache"])
        #expect(!features(arguments, "enable-features=").contains("BackForwardCache"))
    }

    @Test func aFeatureOnBothListsIsDisabled() {
        let arguments = switches(enabled: ["TimerSlackMac", "BackForwardCache"], disabled: ["TimerSlackMac"])
        let enabled = features(arguments, "enable-features=")
        #expect(enabled.contains("BackForwardCache"))
        #expect(!enabled.contains("TimerSlackMac"))
        #expect(features(arguments, "disable-features=") == CEFSwitches.idleServiceOffFeatures + ["TimerSlackMac"])
    }

    /// A feature cmux turns on itself (wake-up alignment, the Chrome prompt off) also loses to an off one.
    @Test func anOffFeatureBeatsOneCmuxNames() {
        let arguments = switches(enabled: [], disabled: ["AlignWakeUps", "IPH_DemoMode"])
        let enabled = features(arguments, "enable-features=")
        #expect(!enabled.contains("AlignWakeUps"))
        #expect(!enabled.contains(CEFSwitches.chromePromptOffFeature))
        #expect(enabled.contains("BatterySaverModeAlignWakeUps"))
        #expect(arguments.filter { $0.hasPrefix("enable-features=") }.count == 1)
    }

    /// With no app feature off, the one disable entry holds only the idle services cmux does not use.
    @Test func noOffFeatureLeavesOnlyTheIdleServicesDisabled() {
        let arguments = switches(enabled: ["TimerSlackMac"], disabled: [])
        let idleServicesOnly = "disable-features=" + CEFSwitches.idleServiceOffFeatures.joined(separator: ",")
        #expect(arguments.filter { $0.hasPrefix("disable-features=") } == [idleServicesOnly])
        #expect(features(arguments, "enable-features=").contains("TimerSlackMac"))
    }

    @Test func anEntryNamesTheFeatureBeforeItsParams() {
        #expect(CEFSwitches.featureName(of: CEFSwitches.chromePromptOffFeature) == "IPH_DemoMode")
        #expect(CEFSwitches.featureName(of: "*Name<Study.Group:param/value") == "Name")
        #expect(CEFSwitches.featureName(of: "TimerSlackMac") == "TimerSlackMac")
    }
}

/// The New Tab and every agent chat are one site (`cmux-page://cmux.agent`). Chrome puts at most 2 main frames
/// of a site in one renderer (ProcessPerSiteMainFrameThreshold, content_features.cc), so 5 chats took 3
/// renderers. With the default-off feature `agentPageRendererSharing`, the agent site's entry in PL-memory's
/// page-scheme switch raises that site's cap. Only a fork whose switch reads the cap table gets it, and only
/// with the renderer paths, where no page holds a DevTools session that would end the sharing.
@Suite struct CEFSwitchesAgentPageSiteTests {
    private func arguments(forkAPI: Int32, rendererPaths: Bool = true, cap: Int? = 8) -> [String] {
        let features = CEFForkFeatures(forkAPIVersion: forkAPI, shimHasRendererPaths: rendererPaths)
        return CEFSwitches.current(forkAPIVersion: forkAPI, rendererPaths: features.rendererPaths,
                                   bundleIdentifier: "com.cmuxterm.app.next", environment: [:],
                                   agentPageMainFrameCap: cap).arguments
    }

    private func pageSchemeArguments(_ arguments: [String]) -> [String] {
        arguments.filter { $0 == CEFSwitches.pageSchemeProcessPerSite || $0.hasPrefix(CEFSwitches.pageSchemeProcessPerSite + "=") }
    }

    @Test func theForkWithTheCapTableGetsTheAgentSiteEntry() {
        #expect(pageSchemeArguments(arguments(forkAPI: CEFSwitches.pageSiteSharingForkAPI))
                == ["cmux-page-scheme-process-per-site=cmux.agent:8"])
    }

    /// API 29 and 30 have the renderer paths but no cap table: the switch would be unknown there.
    @Test(arguments: [Int32(28), 29, CEFSwitches.pageSiteSharingForkAPI - 1])
    func aForkBeforeTheCapTableGetsNoEntry(forkAPI: Int32) {
        #expect(pageSchemeArguments(arguments(forkAPI: forkAPI)).isEmpty)
    }

    @Test func aShimWithoutTheRendererPathsGetsNoEntry() {
        #expect(pageSchemeArguments(arguments(forkAPI: CEFSwitches.pageSiteSharingForkAPI, rendererPaths: false)).isEmpty)
    }

    @Test func theFeatureOffGetsNoEntry() {
        #expect(pageSchemeArguments(arguments(forkAPI: CEFSwitches.pageSiteSharingForkAPI, cap: nil)).isEmpty)
    }

    /// The feature's `mainFrames` param sets the cap; nothing else in the switches changes with it.
    @Test func theFeatureParamSetsTheCap() {
        let four = arguments(forkAPI: CEFSwitches.pageSiteSharingForkAPI, cap: 4)
        #expect(pageSchemeArguments(four) == ["cmux-page-scheme-process-per-site=cmux.agent:4"])
        #expect(four.filter { !$0.hasPrefix(CEFSwitches.pageSchemeProcessPerSite) }
                == arguments(forkAPI: CEFSwitches.pageSiteSharingForkAPI, cap: nil))
    }

    /// The entry names the agent site, not the whole scheme: settings, viewers and passwords keep their own
    /// process reuse. The value parses as `<site>:<mainFrames>`, comma-joined, the format the fork reads.
    @Test func theValueListsOnlyTheAgentSite() throws {
        let argument = try #require(pageSchemeArguments(arguments(forkAPI: CEFSwitches.pageSiteSharingForkAPI)).first)
        let caps = try #require(Self.parse(value: String(argument.dropFirst(CEFSwitches.pageSchemeProcessPerSite.count + 1))))
        #expect(caps == [CEFSwitches.PageSiteCap(site: "cmux.agent", mainFrames: 8)])
        #expect(caps.allSatisfy { FirstPartyPages.ids.contains($0.site) })
    }

    @Test func severalSitesJoinWithCommas() {
        let caps = [CEFSwitches.PageSiteCap(site: "cmux.agent", mainFrames: 8), .init(site: "settings.privileged", mainFrames: 8)]
        let argument = CEFSwitches.pageSchemeProcessPerSiteArgument(caps)
        #expect(argument == "cmux-page-scheme-process-per-site=cmux.agent:8,settings.privileged:8")
        #expect(Self.parse(value: String(argument.dropFirst(CEFSwitches.pageSchemeProcessPerSite.count + 1))) == caps)
    }

    /// The value grammar: one or more `<site>:<mainFrames>` joined by `,`; a site is a non-empty host with no
    /// `:`, `,` or `/`; a cap is a whole number of at least 1. Nil for anything else.
    private static func parse(value: String) -> [CEFSwitches.PageSiteCap]? {
        var caps: [CEFSwitches.PageSiteCap] = []
        for entry in value.split(separator: ",", omittingEmptySubsequences: false) {
            let parts = entry.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty, !parts[0].contains("/"),
                  let frames = Int(parts[1]), frames >= 1 else { return nil }
            caps.append(.init(site: String(parts[0]), mainFrames: frames))
        }
        return caps.isEmpty ? nil : caps
    }
}

/// A CEF pin bump must not put Chromium's commit waits back on the main thread:
/// a page-window resize calls `CATransactionCoordinator::Synchronize`, which waits up to 500 ms
/// before the app's commit and up to 50 ms after it (`ca_transaction_observer.mm`). Every fork
/// version either keeps `AsyncLiveResize` (which skips that call) or skips it itself for a resize
/// with no deadline (fork API 27, e07a2f78).
@Suite struct CEFResizeCommitWaitTests {
    private static func enabledFeatures(forkAPIVersion: Int32) -> [String] {
        CEFSwitches.current(forkAPIVersion: forkAPIVersion, rendererPaths: forkAPIVersion >= CEFForkFeatures.rendererPathsForkAPI,
                            bundleIdentifier: "com.cmuxterm.app.next", environment: [:]).arguments
            .filter { $0.hasPrefix("enable-features=") }
            .flatMap { $0.dropFirst("enable-features=".count).split(separator: ",").map(String.init) }
    }

    @Test func everyForkVersionResizesWithoutACommitWait() {
        for forkAPIVersion in Int32(0)...64 {
            let skipsSynchronize = CEFForkFeatures(forkAPIVersion: forkAPIVersion, shimHasRendererPaths: true)
                .resizeWaitsOnlyForDeadline
            let asyncLiveResize = Self.enabledFeatures(forkAPIVersion: forkAPIVersion).contains("AsyncLiveResize")
            #expect(asyncLiveResize || skipsSynchronize, "fork API \(forkAPIVersion) waits for Chromium's commit on every resize")
        }
    }

    @Test func aForkWithoutTheSkipKeepsAsyncLiveResize() {
        #expect(!CEFForkFeatures(forkAPIVersion: 26, shimHasRendererPaths: false).resizeWaitsOnlyForDeadline)
        #expect(Self.enabledFeatures(forkAPIVersion: 26).contains("AsyncLiveResize"))
    }

    /// The skip keeps the bounded wait a layer-hosted page asks for, which AsyncLiveResize would lose.
    @Test func aForkWithTheSkipDropsAsyncLiveResize() {
        #expect(CEFForkFeatures(forkAPIVersion: 27, shimHasRendererPaths: false).resizeWaitsOnlyForDeadline)
        #expect(!Self.enabledFeatures(forkAPIVersion: 27).contains("AsyncLiveResize"))
        #expect(CEFSwitches.resizeSyncForkAPI == CEFForkFeatures.resizeSyncForkAPI)
    }
}
