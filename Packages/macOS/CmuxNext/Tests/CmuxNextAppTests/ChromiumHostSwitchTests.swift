#if DEBUG || CMUX_BENCH_HOOKS
@testable import CmuxNextApp
import CmuxNextBrowser
import CmuxNextControl
import CmuxNextDesign
import CmuxNextFeatures
import CmuxNextSettings
import CmuxNextWakeups
import Testing

/// The Chromium Host app follows the feature `cefHelperHost`, and Debug Settings
/// `browserHost.helper` is only its local override, in the feature list's order.
@MainActor
@Suite struct ChromiumHostSwitchTests {
    /// Debug Settings as the app holds them, with `helper` set when non-nil.
    private static func tunables(helper: Bool? = nil) -> TunableStore {
        let store = TunableStore()
        store.register(BrowserHostTunables.all)
        store.activate(file: nil)
        if let helper { store.set(BrowserHostTunables.helper.key, .bool(helper)) }
        return store
    }

    private static func features(_ channel: Feature.Channel = .dev, enabled: Set<String> = [],
                                 disabled: Set<String> = [], policyDisabled: Set<String> = []) -> FeatureList {
        FeatureList(registry: FeatureRegistry(), channel: channel,
                    overrides: FeatureOverrides(policyDisabled: policyDisabled, environmentDisabled: disabled,
                                                environmentEnabled: enabled))
    }

    private static func hostSwitch(_ features: FeatureList, _ tunables: TunableStore) -> BrowserHostSwitch {
        AppControl.chromiumHostSwitch(in: features, tunables: tunables)
    }

    @Test func theFeatureIsAPerfPathBenchedByItsStories() {
        #expect(Feature.cefHelperHost.kind == .perfPath)
        #expect(Feature.cefHelperHost.process == .app)
        #expect(Feature.cefHelperHost.runtimeMutable == false)
        #expect(Feature.cefHelperHost.stories == ["chromium-host", "crash-survival"])
    }

    @Test(arguments: Feature.Channel.allCases)
    func theHostIsOffByDefaultOnEveryChannel(_ channel: Feature.Channel) {
        let hostSwitch = Self.hostSwitch(Self.features(channel), Self.tunables())
        #expect(hostSwitch.isEnabled == false)
        #expect(BrowserHostTunables.backend(hostEnabled: hostSwitch.isEnabled) == .inProcess)
    }

    /// An environment decision (`CMUX_ENABLE_FEATURES` in the list's overrides) turns the host on with no toggle.
    /// A launched app never sees an inherited `CMUX_ENABLE_FEATURES` (LaunchIdentity strips it), so benches turn
    /// the host on through the tunables file's `browserHost.helper` instead.
    @Test func theEnvironmentTurnsItOn() {
        let hostSwitch = Self.hostSwitch(Self.features(enabled: ["cefHelperHost"]), Self.tunables())
        #expect(hostSwitch.isEnabled)
        #if DEBUG
        #expect(BrowserHostTunables.backend(hostEnabled: hostSwitch.isEnabled) == .host)
        #else
        // A bench build measures the host but never moves a tab to it.
        #expect(BrowserHostTunables.backend(hostEnabled: hostSwitch.isEnabled) == .inProcess)
        #endif
    }

    /// The bench tunables file's `browserHost.helper` (chromium-host-bench.py) still turns it on,
    /// and the switch follows the toggle after the launch.
    @Test(arguments: [Feature.Channel.dev, .nightly])
    func theToggleIsTheLocalOverride(_ channel: Feature.Channel) {
        let store = Self.tunables()
        let hostSwitch = Self.hostSwitch(Self.features(channel), store)
        #expect(hostSwitch.localOverride == nil)
        store.set(BrowserHostTunables.helper.key, .bool(true))
        #expect(hostSwitch.localOverride == true)
        #expect(hostSwitch.isEnabled)
        store.set(BrowserHostTunables.helper.key, .bool(false))
        #expect(hostSwitch.isEnabled == false)
    }

    /// Steps 1 and 2 beat step 3: policy and `CMUX_DISABLE_FEATURES` keep the host off with the toggle on,
    /// and `CMUX_ENABLE_FEATURES` keeps it on with the toggle off.
    @Test func policyAndTheEnvironmentBeatTheToggle() {
        #expect(!Self.hostSwitch(Self.features(policyDisabled: ["cefHelperHost"]), Self.tunables(helper: true)).isEnabled)
        #expect(!Self.hostSwitch(Self.features(disabled: ["cefHelperHost"]), Self.tunables(helper: true)).isEnabled)
        #expect(Self.hostSwitch(Self.features(enabled: ["cefHelperHost"]), Self.tunables(helper: false)).isEnabled)
    }

    /// `features.list` (and so a bench's features snapshot) reports what the switch runs with: the toggle's value,
    /// source `local`, while it is set and taken; the launch's resolution otherwise.
    @Test(arguments: [Feature.Channel.dev, .nightly, .release])
    func theReportFollowsTheSwitch(_ channel: Feature.Channel) throws {
        let store = Self.tunables()
        let features = Self.features(channel)
        let hostSwitch = Self.hostSwitch(features, store)
        let report = FeatureFlagsPage.report(features, tunables: store, daemon: nil)
        for toggle in [true, false, nil] as [Bool?] {
            store.set(BrowserHostTunables.helper.key, toggle.map(TunableValue.bool))
            let resolution = report.resolution(of: .cefHelperHost)
            #expect(resolution.isEnabled == hostSwitch.isEnabled)
            #expect(resolution.source == (hostSwitch.localOverride == nil ? .channelDefault : .local))
            let rows = try #require(report.json["features"]?.arrayValue)
            let row = try #require(rows.first { $0["name"]?.stringValue == Feature.cefHelperHost.name })
            #expect(row["state"]?.stringValue == (hostSwitch.isEnabled ? "on" : "off"))
            #expect(row["source"]?.stringValue == resolution.source.description)
        }
        store.set(BrowserHostTunables.helper.key, .bool(true))
        #expect(report.resolution(of: .cefHelperHost).isEnabled == (channel != .release))
    }

    /// Policy and the environment keep their source in the report with the toggle set.
    @Test func theReportKeepsPolicyAndTheEnvironment() {
        let store = Self.tunables(helper: true)
        let disabled = FeatureFlagsPage.report(Self.features(disabled: ["cefHelperHost"]), tunables: store, daemon: nil)
        #expect(disabled.resolution(of: .cefHelperHost) == Feature.Resolution(isEnabled: false, source: .environment))
        let policy = FeatureFlagsPage.report(Self.features(policyDisabled: ["cefHelperHost"]), tunables: store, daemon: nil)
        #expect(policy.resolution(of: .cefHelperHost) == Feature.Resolution(isEnabled: false, source: .policy))
    }

    /// The host on alone keeps Chromium tabs in cmux (`debug.chromium_host` beside in-process tabs, as
    /// chromium-host-bench.py's inproc rows need); with `chromiumHostTabs` too, AppServices builds the one
    /// supervisor every tab attaches through.
    @Test func tabsMoveToTheHostOnlyWithChromiumHostTabs() {
        let work = BackgroundWork(label: "test.chromium-host-switch")
        let mainWork = MainWorkScheduler(budget: MainFrameBudget())
        let helperOnly = Self.features(enabled: ["cefHelperHost"])
        #expect(AppServices.chromiumHostSupervisor(work: work, mainWork: mainWork, features: helperOnly) == nil)
        let tabsOnly = Self.features(enabled: ["chromiumHostTabs"])
        #expect(AppServices.chromiumHostSupervisor(work: work, mainWork: mainWork, features: tabsOnly) == nil)
        let both = Self.features(enabled: ["cefHelperHost", "chromiumHostTabs"])
        let supervisor = AppServices.chromiumHostSupervisor(work: work, mainWork: mainWork, features: both)
        #if DEBUG
        #expect(supervisor is ChromiumHostSupervisor)
        #else
        // A bench build measures the host but never moves a tab to it.
        #expect(supervisor == nil)
        #endif
    }

    /// Release takes no local override, even from an active store.
    @Test func releaseIgnoresTheToggle() {
        let hostSwitch = Self.hostSwitch(Self.features(.release), Self.tunables(helper: true))
        #expect(hostSwitch.takesLocalOverride == false)
        #expect(hostSwitch.isEnabled == false)
    }
}
#endif
