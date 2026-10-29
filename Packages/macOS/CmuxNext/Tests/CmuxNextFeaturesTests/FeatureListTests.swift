import Atomics
import CmuxNextCompat
import CmuxNextFeatures
import Darwin
import Foundation
import Testing

/// The FeatureList resolution ladder (p12-perf-process.md section 3.9), the
/// sources it reports, early-read recording and the cost of a lookup.
struct FeatureListTests {
    private static let perf = feature(0, "perfThing", FeatureDefaults(dev: true, nightly: false, release: false), .perfPath)
    private static let kill = feature(1, "killThing", FeatureDefaults(all: true), .killSwitch, sticky: true)
    private static let labs = feature(2, "labsThing", FeatureDefaults(all: false), .labs)
    private static let registry = FeatureRegistry([perf, kill, labs])

    /// A test declaration: the fields the list does not read take neutral values.
    private static func feature(
        _ index: Int,
        _ name: String,
        _ defaults: FeatureDefaults,
        _ kind: Feature.Kind,
        sticky: Bool = false
    ) -> Feature {
        Feature(
            index: index,
            name: name,
            owner: "PL-test",
            description: "A test feature.",
            kind: kind,
            process: .app,
            chromiumFeature: nil,
            defaults: defaults,
            expires: nil,
            params: [],
            stories: [],
            sticky: sticky,
            runtimeMutable: false
        )
    }

    // MARK: Ladder

    @Test func aNameOnBothEnvironmentListsIsDisabled() {
        let overrides = FeatureOverrides(environment: [
            FeatureOverrides.disableVariable: "killThing, labsThing",
            FeatureOverrides.enableVariable: "labsThing,killThing",
        ])
        let list = FeatureList(registry: Self.registry, channel: .nightly, overrides: overrides)
        #expect(list.resolution(of: Self.kill) == Feature.Resolution(isEnabled: false, source: .environment))
        #expect(list.resolution(of: Self.labs) == Feature.Resolution(isEnabled: false, source: .environment))
    }

    @Test func theEnableListTurnsAFeatureOn() {
        let overrides = FeatureOverrides(environment: [FeatureOverrides.enableVariable: "labsThing"])
        let list = FeatureList(registry: Self.registry, channel: .release, overrides: overrides)
        #expect(list.isEnabled(Self.labs))
        #expect(list.resolution(of: Self.labs).source == .environment)
    }

    @Test func policyBeatsTheEnvironment() {
        let overrides = FeatureOverrides(policyDisabled: ["labsThing"], environment: [FeatureOverrides.enableVariable: "labsThing"])
        let list = FeatureList(registry: Self.registry, channel: .dev, overrides: overrides)
        #expect(list.resolution(of: Self.labs) == Feature.Resolution(isEnabled: false, source: .policy))
    }

    /// CEF's `--enable-features` gets the Chromium name of each enabled `chromium` feature, and nothing for
    /// an off one or one of another process (`cefTimerSlack` is `TimerSlackMac`).
    @Test func enabledChromiumFeaturesNameOnlyTheOnesThatAreOn() {
        func chromium(_ index: Int, _ name: String, _ chromiumName: String) -> Feature {
            Feature(index: index, name: name, owner: "PL-test", description: "A test feature.", kind: .perfPath,
                    process: .chromium, chromiumFeature: chromiumName, defaults: FeatureDefaults(all: false),
                    expires: nil, params: [], stories: [], sticky: false, runtimeMutable: false)
        }
        let slack = chromium(3, "slackThing", "TimerSlackMac")
        let align = chromium(4, "alignThing", "AlignWakeUps")
        let registry = FeatureRegistry([Self.perf, Self.kill, Self.labs, slack, align])
        let overrides = FeatureOverrides(environment: [FeatureOverrides.enableVariable: "slackThing,labsThing"])
        let list = FeatureList(registry: registry, channel: .release, overrides: overrides)
        #expect(list.enabledChromiumFeatures == ["TimerSlackMac"])
        #expect(FeatureList(registry: registry, channel: .release).enabledChromiumFeatures.isEmpty)
    }

    /// CEF's `--disable-features` gets the Chromium name of each off `chromium` feature:
    /// a remote off of a feature that is on by default is off in Chromium, not left to Chromium's own default,
    /// and a name on both environment lists is off.
    @Test func disabledChromiumFeaturesNameEveryOffOne() {
        func chromium(_ index: Int, _ name: String, _ chromiumName: String, on: Bool) -> Feature {
            Feature(index: index, name: name, owner: "PL-test", description: "A test feature.", kind: .perfPath,
                    process: .chromium, chromiumFeature: chromiumName, defaults: FeatureDefaults(all: on),
                    expires: nil, params: [], stories: [], sticky: false, runtimeMutable: false)
        }
        let cache = chromium(3, "cacheThing", "BackForwardCache", on: true)
        let slack = chromium(4, "slackThing", "TimerSlackMac", on: false)
        let align = chromium(5, "alignThing", "AlignWakeUps", on: false)
        let registry = FeatureRegistry([Self.perf, Self.kill, Self.labs, cache, slack, align])
        let remoteOff = FeatureList(registry: registry, channel: .release, overrides: FeatureOverrides(remote: ["cacheThing": false]))
        #expect(remoteOff.resolution(of: cache) == Feature.Resolution(isEnabled: false, source: .remote))
        #expect(remoteOff.disabledChromiumFeatures == ["BackForwardCache", "TimerSlackMac", "AlignWakeUps"])
        #expect(remoteOff.enabledChromiumFeatures.isEmpty)
        let both = FeatureList(registry: registry, channel: .release, overrides: FeatureOverrides(environment: [
            FeatureOverrides.enableVariable: "alignThing,slackThing",
            FeatureOverrides.disableVariable: "alignThing",
        ]))
        #expect(both.enabledChromiumFeatures == ["BackForwardCache", "TimerSlackMac"])
        #expect(both.disabledChromiumFeatures == ["AlignWakeUps"])
    }

    @Test func aLocalOverrideIsIgnoredInRelease() {
        let local = RecordingLocalOverrides(["labsThing": true, "killThing": false])
        let list = FeatureList(registry: Self.registry, channel: .release, local: local)
        #expect(list.resolution(of: Self.labs) == Feature.Resolution(isEnabled: false, source: .channelDefault))
        #expect(list.resolution(of: Self.kill) == Feature.Resolution(isEnabled: true, source: .channelDefault))
        #expect(local.asked.load(ordering: .relaxed) == 0)
    }

    @Test(arguments: [Feature.Channel.dev, .nightly])
    func aLocalOverrideAppliesInDevAndNightly(channel: Feature.Channel) {
        let local = RecordingLocalOverrides(["labsThing": true])
        let list = FeatureList(registry: Self.registry, channel: channel, overrides: FeatureOverrides(remote: ["labsThing": false]), local: local)
        #expect(list.resolution(of: Self.labs) == Feature.Resolution(isEnabled: true, source: .local))
    }

    @Test func theEnvironmentBeatsALocalOverride() {
        let local = RecordingLocalOverrides(["labsThing": true])
        let overrides = FeatureOverrides(environment: [FeatureOverrides.disableVariable: "labsThing"])
        let list = FeatureList(registry: Self.registry, channel: .dev, overrides: overrides, local: local)
        #expect(list.resolution(of: Self.labs) == Feature.Resolution(isEnabled: false, source: .environment))
    }

    @Test func eachValueReportsTheInputThatDecidedIt() {
        let perf2 = Self.feature(3, "remoteThing", FeatureDefaults(all: true), .perfPath)
        let trial = Self.feature(4, "trialThing", FeatureDefaults(all: false), .perfPath)
        let quiet = Self.feature(5, "quietThing", FeatureDefaults(dev: false, nightly: true, release: false), .perfPath)
        let registry = FeatureRegistry([Self.perf, Self.kill, Self.labs, perf2, trial, quiet])
        let overrides = FeatureOverrides(
            policyDisabled: ["perfThing"],
            environmentDisabled: ["killThing"],
            remote: ["remoteThing": false, "trialThing": false],
            fieldTrial: ["trialThing": true]
        )
        let list = FeatureList(registry: registry, channel: .nightly, overrides: overrides, local: RecordingLocalOverrides(["labsThing": true]))
        let described = list.entries.map { "\($0.feature.name) \($0.resolution)" }
        #expect(described == [
            "perfThing off source=policy",
            "killThing off source=env",
            "labsThing on source=local",
            "remoteThing off source=remote",
            "trialThing off source=remote",
            "quietThing on source=default",
        ])
        let trialOnly = FeatureList(registry: registry, channel: .nightly, overrides: FeatureOverrides(fieldTrial: ["trialThing": true]))
        #expect(trialOnly.resolution(of: trial) == Feature.Resolution(isEnabled: true, source: .fieldTrial))
    }

    /// The channel filter is the study's (``FieldTrials``, FieldTrialTests): a Release build gets an arm only from
    /// a study that names `release`, so the list applies the arms it is given on every channel.
    @Test func fieldTrialArmsApplyOnEveryChannelTheyAreGiven() {
        let overrides = FeatureOverrides(fieldTrial: ["labsThing": true])
        for channel in Feature.Channel.allCases {
            let list = FeatureList(registry: Self.registry, channel: channel, overrides: overrides)
            #expect(list.resolution(of: Self.labs) == Feature.Resolution(isEnabled: true, source: .fieldTrial))
        }
    }

    @Test func theChannelDefaultIsUsedWithNoInput() {
        #expect(FeatureList(registry: Self.registry, channel: .dev).isEnabled(Self.perf))
        #expect(!FeatureList(registry: Self.registry, channel: .nightly).isEnabled(Self.perf))
        #expect(!FeatureList(registry: Self.registry, channel: .release).isEnabled(Self.perf))
    }

    @Test func unknownNamesAreIgnoredAndReported() {
        let overrides = FeatureOverrides(
            policyDisabled: ["apps"],
            environment: [FeatureOverrides.enableVariable: "labsThing,ghost"],
            remote: ["gone": false]
        )
        let list = FeatureList(registry: Self.registry, channel: .dev, overrides: overrides)
        #expect(list.unknownNames == ["apps", "ghost", "gone"])
        #expect(list.isEnabled(Self.labs))
    }

    @Test func environmentListsAreTrimmedAndSkipEmptyNames() {
        #expect(FeatureOverrides.names(in: " a ,\tb,,c ,") == ["a", "b", "c"])
        #expect(FeatureOverrides.names(in: nil).isEmpty)
        #expect(FeatureOverrides.names(in: " , ").isEmpty)
        #expect(FeatureOverrides.names(in: "a,\nb\r\n, c\n") == ["a", "b", "c"])
    }

    @Test func buildKindsMapToChannels() {
        #expect(Feature.Channel(BuildIdentity.Kind.nightly) == .nightly)
        #expect(Feature.Channel(BuildIdentity.Kind.release) == .release)
        #expect(Feature.Channel(BuildIdentity.Kind.rc) == .release)
        #expect(Feature.Channel(BuildIdentity.Kind.dev) == .dev)
        #expect(Feature.Channel(BuildIdentity.Kind.staging) == .dev)
        #expect(Feature.Channel(BuildIdentity.Kind.unbundled) == .dev)
    }

    @Test func theRegistryFindsFeaturesByName() {
        #expect(Self.registry.feature(named: "killThing") == Self.kill)
        #expect(Self.registry.feature(named: "nope") == nil)
        #expect(Self.registry.contains(Self.labs))
        #expect(!Self.registry.contains(Self.feature(2, "other", FeatureDefaults(all: false), .labs)))
    }

    /// The literal shape gen-features.py writes (schemas/features/README.md,
    /// "Generated interface"), so a generated registry compiles against Feature.
    @Test func aGeneratorShapedDeclarationCompilesAndRegisters() {
        let generated = Feature(
            index: 0,
            name: "cefLayerHosting",
            owner: "PL-cef-layer",
            description: "Host Chromium pages in the window's layers.",
            kind: .perfPath,
            process: .chromium,
            chromiumFeature: "CefLayerHosting",
            defaults: FeatureDefaults(dev: true, nightly: true, release: false),
            expires: "2026-12-20",
            params: [
                FeatureParamSpec(
                    name: "syncDeadline",
                    description: "Longest wait for the page's resized frame.",
                    value: .duration(default: 0.05, min: 0.0, max: 1.0)
                ),
                FeatureParamSpec(name: "retries", description: "Retries.", value: .int(default: 2, min: 0, max: 8)),
                FeatureParamSpec(name: "scale", description: "Scale.", value: .double(default: 1.5, min: 1.0, max: 2.0)),
                FeatureParamSpec(name: "eager", description: "Eager.", value: .bool(default: false)),
            ],
            stories: ["browse-heavy"],
            sticky: false,
            runtimeMutable: false
        )
        let registry = FeatureRegistry([generated])
        #expect(registry.feature(named: "cefLayerHosting")?.description == "Host Chromium pages in the window's layers.")
        #expect(registry.feature(named: "cefLayerHosting")?.params.first?.value == FeatureParamValue.duration(default: 0.05, min: 0, max: 1))
        #expect(FeatureList(registry: registry, channel: .release).resolution(of: generated) == Feature.Resolution(isEnabled: false, source: .channelDefault))
        #expect(FeatureRegistry().features == Feature.registered)
    }

    /// A daemon whose launch filters what it inherits (a Team-signed acpmux spawn) gets the app's
    /// overridden daemon features, and only those: app features and channel defaults stay out.
    @Test func theDaemonEnvironmentCarriesOnlyOverriddenDaemonFeatures() {
        let overrides = FeatureOverrides(policyDisabled: ["killThing"], environment: [
            FeatureOverrides.enableVariable: "leftoverDaemonIdleExit,perfThing",
        ])
        let list = FeatureList(registry: FeatureRegistry(), channel: .release, overrides: overrides)
        #expect(list.isEnabled(.leftoverDaemonIdleExit))
        #expect(list.daemonEnvironment == [FeatureOverrides.enableVariable: "leftoverDaemonIdleExit"])
        let none = FeatureList(registry: FeatureRegistry(), channel: .release)
        #expect(none.daemonEnvironment.isEmpty)
        let disabled = FeatureList(registry: FeatureRegistry(), channel: .release, overrides: FeatureOverrides(
            policyDisabled: ["leftoverDaemonIdleExit"], environmentEnabled: ["leftoverDaemonIdleExit"]))
        #expect(disabled.daemonEnvironment == [FeatureOverrides.disableVariable: "leftoverDaemonIdleExit"])
    }

    // MARK: Early reads

    @Test func aReadBeforeInstallIsRecordedAndAnswersTheDefault() {
        let slot = FeatureList.Slot(registry: Self.registry, channel: .release, recordsEarlyReads: true)
        #expect(!slot.isEnabled(Self.labs))
        #expect(slot.isEnabled(Self.kill))
        #expect(slot.earlyReads == [Self.kill, Self.labs])

        let overrides = FeatureOverrides(environment: [FeatureOverrides.enableVariable: "labsThing"])
        let stale = slot.install(FeatureList(registry: Self.registry, channel: .release, overrides: overrides))
        #expect(stale == [Self.labs])
        #expect(slot.isEnabled(Self.labs))
        #expect(slot.list?.resolution(of: Self.labs).source == .environment)
        #expect(slot.earlyReads == [Self.kill, Self.labs])
    }

    @Test func aSlotThatDoesNotRecordKeepsNoEarlyReads() {
        let slot = FeatureList.Slot(registry: Self.registry, channel: .dev, recordsEarlyReads: false)
        #expect(slot.isEnabled(Self.perf))
        #expect(slot.earlyReads.isEmpty)
        #expect(slot.install(FeatureList(registry: Self.registry, channel: .dev, overrides: FeatureOverrides(environmentDisabled: ["perfThing"]))).isEmpty)
        #expect(!slot.isEnabled(Self.perf))
    }

    /// A duration param reads as its declared default; another name or another type reads as nil.
    @Test func aDurationParamReadsItsDefault() {
        #expect(Feature.intentPrewarmHover.durationParam("dwell") == .milliseconds(200))
        #expect(Feature.intentPrewarmHover.durationParam("missing") == nil)
        #expect(Self.perf.durationParam("dwell") == nil)
    }

    /// Readers on other threads race install: when a reader answered the
    /// default and the installed list says otherwise, install reports that
    /// feature (the handshake in Slot.isEnabled and Slot.install).
    @Test func anEarlyReadThatRacesInstallIsReported() async {
        let readers = 4
        let installed = FeatureList(
            registry: Self.registry,
            channel: .release,
            overrides: FeatureOverrides(environmentEnabled: ["labsThing"])
        )
        for round in 0..<300 {
            let slot = FeatureList.Slot(registry: Self.registry, channel: .release, recordsEarlyReads: true)
            let started = ManagedAtomic<Int>(0)
            let finished = ManagedAtomic<Int>(0)
            let go = ManagedAtomic<Bool>(false)
            let sawDefault = ManagedAtomic<Bool>(false)
            var reported: [Feature] = []
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                for _ in 0..<readers {
                    Thread.detachNewThread {
                        started.wrappingIncrement(ordering: .relaxed)
                        while !go.load(ordering: .acquiring) {}
                        for _ in 0..<64 where !slot.isEnabled(Self.labs) {
                            sawDefault.store(true, ordering: .relaxed)
                        }
                        if finished.wrappingIncrementThenLoad(ordering: .acquiringAndReleasing) == readers {
                            continuation.resume()
                        }
                    }
                }
                while started.load(ordering: .relaxed) < readers {}
                go.store(true, ordering: .releasing)
                reported = slot.install(installed)
            }
            if sawDefault.load(ordering: .relaxed) {
                #expect(reported == [Self.labs], "round \(round): a reader answered the default, install reported \(reported.map(\.name))")
            }
            #expect(slot.isEnabled(Self.labs))
        }
    }

    // MARK: Cost

    /// A lookup adds no allocation to the loop that makes it: each count is
    /// compared with the same loop around a constant, because the Debug
    /// build's loop allocates by itself (7 per outer pass on the fleet).
    @Test func aLookupAllocatesNothing() throws {
        let list = FeatureList(registry: Self.registry, channel: .nightly, overrides: FeatureOverrides(remote: ["labsThing": true]))
        let slot = FeatureList.Slot(registry: Self.registry, channel: .nightly)
        slot.install(list)
        let features = Self.registry.features
        var on = 0
        func allocations(_ lookup: (Feature) -> Bool) -> Int? {
            MallocProbe.allocations {
                for _ in 0..<10_000 {
                    for feature in features where lookup(feature) { on += 1 }
                }
            }
        }

        let control = MallocProbe.allocations { on += ContiguousArray(repeating: 1, count: 64).count }
        try #require((control ?? 0) > 0, "malloc_logger saw no allocation on this thread: the probe cannot measure here")

        let baseline = try #require(allocations { _ in true })
        let listLookups = allocations { list.isEnabled($0) }
        let slotLookups = allocations { slot.isEnabled($0) }
        #expect(listLookups == baseline, "the loop alone made \(baseline)")
        #expect(slotLookups == baseline, "the loop alone made \(baseline)")
        #expect(on > 0)
    }
}

/// A local provider that counts how often it is asked.
private final class RecordingLocalOverrides: FeatureLocalOverrideProvider {
    let values: [String: Bool]
    let asked = ManagedAtomic<Int>(0)

    init(_ values: [String: Bool]) { self.values = values }

    func localOverride(for feature: Feature) -> Bool? {
        asked.wrappingIncrement(ordering: .relaxed)
        return values[feature.name]
    }
}

/// Counts the allocations one thread makes, through libmalloc's
/// `malloc_logger` hook (the one malloc stack logging uses).
private struct MallocProbe {
    typealias Logger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void

    /// `MALLOC_LOG_TYPE_ALLOCATE` (libmalloc stack_logging.h).
    static let allocateType: UInt32 = 2
    static let count = ManagedAtomic<Int>(0)
    static let thread = ManagedAtomic<UInt64>(0)

    /// The allocations `body` makes on this thread, or nil when the hook is missing.
    static func allocations(_ body: () -> Void) -> Int? {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger") else { return nil }
        let slot = symbol.assumingMemoryBound(to: Logger?.self)
        var id: UInt64 = 0
        pthread_threadid_np(nil, &id)
        count.store(0, ordering: .relaxed)
        thread.store(id, ordering: .relaxed)
        let previous = slot.pointee
        slot.pointee = { type, _, _, _, _, _ in
            guard type & MallocProbe.allocateType != 0 else { return }
            var id: UInt64 = 0
            pthread_threadid_np(nil, &id)
            if id == MallocProbe.thread.load(ordering: .relaxed) { MallocProbe.count.wrappingIncrement(ordering: .relaxed) }
        }
        body()
        slot.pointee = previous
        thread.store(0, ordering: .relaxed)
        return count.load(ordering: .relaxed)
    }
}
