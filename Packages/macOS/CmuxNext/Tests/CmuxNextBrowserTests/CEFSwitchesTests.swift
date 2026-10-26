@testable import CmuxNextBrowser
import CmuxNextFeatures
import Foundation
import Testing

/// cmux features of process `chromium` reach CEF's `--enable-features` and `--disable-features`
/// (p12-perf-process.md section 3.9), and a Chromium feature on both lists is off, as in Chromium
/// (FeatureList::InitFromCommandLine, base/feature_list.cc).
struct CEFSwitchesTests {
    private static let lensOff = chromium(0, "lensOverlay", "LensOverlay", FeatureDefaults(all: true))
    private static let asyncResize = chromium(1, "asyncLiveResize", "AsyncLiveResize", FeatureDefaults(all: true))
    private static let glicOn = chromium(2, "glic", "Glic", FeatureDefaults(all: false))
    private static let appOnly = Feature(
        index: 3, name: "appThing", owner: "PL-test", description: "A test app feature.", kind: .perfPath,
        process: .app, chromiumFeature: nil, defaults: FeatureDefaults(all: true), expires: "2026-12-01",
        params: [], stories: [], sticky: false, runtimeMutable: false
    )
    private static let registry = FeatureRegistry([lensOff, asyncResize, glicOn, appOnly])

    private static func chromium(_ index: Int, _ name: String, _ chromiumName: String, _ defaults: FeatureDefaults) -> Feature {
        Feature(
            index: index, name: name, owner: "PL-test", description: "A test Chromium feature.", kind: .killSwitch,
            process: .chromium, chromiumFeature: chromiumName, defaults: defaults, expires: nil,
            params: [], stories: [], sticky: false, runtimeMutable: false
        )
    }

    private static func arguments(_ overrides: FeatureOverrides, forkAPIVersion: Int32 = 7) -> [String] {
        let list = FeatureList(registry: registry, channel: .release, overrides: overrides)
        return CEFSwitches.current(
            forkAPIVersion: forkAPIVersion,
            bundleIdentifier: "com.cmuxterm.app.next",
            environment: [:],
            chromiumFeatures: CEFSwitches.ChromiumFeatures(list)
        ).arguments
    }

    /// Every feature name on the switches that start with `prefix`, without params or a study.
    private static func names(_ arguments: [String], _ prefix: String) -> [String] {
        arguments.filter { $0.hasPrefix(prefix) }
            .flatMap { $0.dropFirst(prefix.count).split(separator: ",") }
            .map { String($0.prefix { $0 != ":" && $0 != "<" }) }
    }

    private static func enabled(_ arguments: [String]) -> [String] { names(arguments, CEFSwitches.enableFeaturesPrefix) }
    private static func disabled(_ arguments: [String]) -> [String] { names(arguments, CEFSwitches.disableFeaturesPrefix) }

    @Test func aRemoteOffIsOnTheDisableListAndNotTheEnableList() {
        let switches = Self.arguments(FeatureOverrides(remote: ["glic": true, "lensOverlay": false]))
        #expect(Self.disabled(switches).contains("LensOverlay"))
        #expect(!Self.enabled(switches).contains("LensOverlay"))
        #expect(Self.enabled(switches).contains("Glic"))
        #expect(!Self.disabled(switches).contains("Glic"))
    }

    @Test func aNameOnBothEnvironmentListsIsDisabledInChromium() {
        let switches = Self.arguments(FeatureOverrides(environment: [
            FeatureOverrides.disableVariable: "glic",
            FeatureOverrides.enableVariable: "glic",
        ]))
        #expect(Self.disabled(switches).contains("Glic"))
        #expect(!Self.enabled(switches).contains("Glic"))
    }

    /// A Chromium feature cmux already enables (AsyncLiveResize before fork API 27) is off when a
    /// cmux feature turns it off: the disable list wins, and the emptied enable switch goes.
    @Test func aFeatureCEFSwitchesEnablesIsDisabledWhenACmuxFeatureTurnsItOff() {
        let base = Self.arguments(FeatureOverrides())
        #expect(Self.enabled(base).contains("AsyncLiveResize"))

        let switches = Self.arguments(FeatureOverrides(remote: ["asyncLiveResize": false]))
        #expect(Self.disabled(switches).contains("AsyncLiveResize"))
        #expect(!Self.enabled(switches).contains("AsyncLiveResize"))
        #expect(!switches.contains("enable-features=AsyncLiveResize"), "an emptied enable-features switch is left")
        // The prompt-off switches stay.
        #expect(switches.contains("no-first-run"))
        #expect(switches.contains("enable-features=IPH_DemoMode:chosen_feature/IPH_Dummy"))
    }

    @Test func onlyChromiumProcessFeaturesAreMapped() {
        let states = CEFSwitches.ChromiumFeatures(FeatureList(registry: Self.registry, channel: .release))
        #expect(states.enabled == ["LensOverlay", "AsyncLiveResize"])
        #expect(states.disabled == ["Glic"])
    }

    /// The launch inputs both Chromiums start with: `CMUX_DISABLE_FEATURES` turns a Chromium
    /// feature off, and the build channel of the bundle picks the defaults.
    @Test func theLaunchEnvironmentDecidesTheChromiumFeatures() {
        let states = CEFSwitches.ChromiumFeatures(
            launchEnvironment: [FeatureOverrides.disableVariable: "lensOverlay"],
            bundleIdentifier: "com.cmuxterm.app.next", registry: Self.registry
        )
        #expect(states.disabled.contains("LensOverlay"))
        #expect(!states.enabled.contains("LensOverlay"))
        #expect(states.enabled.contains("AsyncLiveResize"))
    }

    /// The out-of-process Chromium host gets the same states as the in-process engine.
    @Test func theChromiumHostCarriesADisabledFeatureToDisableFeatures() {
        let root = URL(filePath: "/nonexistent/cmux")
        let layout = CEFRuntimeLayout(frameworksDirectory: root, mainBundle: root, helperApp: root)
        let arguments = ChromiumHostConfiguration.arguments(
            layout: layout, rootCache: root, bundleIdentifier: "com.cmuxterm.app.next",
            environment: [FeatureOverrides.disableVariable: "lensOverlay"], registry: Self.registry
        )
        let switches = arguments.filter { $0.hasPrefix("--cef-switch=") }.map { String($0.dropFirst("--cef-switch=".count)) }
        #expect(Self.disabled(switches).contains("LensOverlay"))
        #expect(!Self.enabled(switches).contains("LensOverlay"))
    }

    @Test func aPolicyOffBeatsAnEnvironmentOn() {
        let switches = Self.arguments(FeatureOverrides(
            policyDisabled: ["glic"],
            environment: [FeatureOverrides.enableVariable: "glic"]
        ))
        #expect(Self.disabled(switches).contains("Glic"))
        #expect(!Self.enabled(switches).contains("Glic"))
    }

    /// The disable list matches by feature name, not by the whole entry: params and a study do not hide it.
    @Test func theDisableListWinsOverAnEnableEntryWithParamsOrAStudy() {
        let switches = CEFSwitches.disableWins([
            "enable-features=IPH_DemoMode:chosen_feature/IPH_Dummy,Kept",
            "enable-features=*Glic<Study.Group",
            "disable-features=IPH_DemoMode, Glic",
            "no-first-run",
        ])
        #expect(switches == ["enable-features=Kept", "disable-features=IPH_DemoMode, Glic", "no-first-run"])
    }

    @Test func noChromiumFeaturesLeaveTheSwitchesAsTheyWere() {
        let plain = CEFSwitches.current(forkAPIVersion: 7, bundleIdentifier: "com.cmuxterm.app.next", environment: [:]).arguments
        #expect(CEFSwitches.disableWins(plain) == plain)
        #expect(plain.contains("enable-features=AsyncLiveResize"))
        #expect(plain.contains("enable-features=IPH_DemoMode:chosen_feature/IPH_Dummy"))
    }
}
