import Atomics
import CmuxNextCompat
import CmuxNextFeatures
import Darwin
import Testing

/// The FeatureList resolution ladder (p12-perf-process.md section 3.9), the
/// sources it reports, early-read recording and the cost of a lookup.
struct FeatureListTests {
    private static let perf = Feature(index: 0, name: "perfThing", defaults: Feature.Defaults(dev: true, nightly: false, release: false), kind: .perfPath)
    private static let kill = Feature(index: 1, name: "killThing", defaults: Feature.Defaults(all: true), kind: .killSwitch, isSticky: true)
    private static let labs = Feature(index: 2, name: "labsThing", defaults: Feature.Defaults(all: false), kind: .labs)
    private static let registry = FeatureRegistry([perf, kill, labs])

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
        let perf2 = Feature(index: 3, name: "remoteThing", defaults: Feature.Defaults(all: true), kind: .perfPath)
        let trial = Feature(index: 4, name: "trialThing", defaults: Feature.Defaults(all: false), kind: .perfPath)
        let quiet = Feature(index: 5, name: "quietThing", defaults: Feature.Defaults(dev: false, nightly: true, release: false), kind: .perfPath)
        let registry = FeatureRegistry([Self.perf, Self.kill, Self.labs, perf2, trial, quiet])
        let overrides = FeatureOverrides(
            policyDisabled: ["perfThing"],
            environmentDisabled: ["killThing"],
            remote: ["remoteThing": false, "trialThing": false],
            fieldTrial: ["trialThing": true]
        )
        let list = FeatureList(registry: registry, channel: .nightly, overrides: overrides, local: RecordingLocalOverrides(["labsThing": true]))
        let described = list.entries.map { "\($0.feature) \($0.resolution)" }
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

    @Test func fieldTrialArmsApplyOnlyOnNightly() {
        let overrides = FeatureOverrides(fieldTrial: ["labsThing": true])
        #expect(FeatureList(registry: Self.registry, channel: .nightly, overrides: overrides).isEnabled(Self.labs))
        #expect(!FeatureList(registry: Self.registry, channel: .dev, overrides: overrides).isEnabled(Self.labs))
        #expect(!FeatureList(registry: Self.registry, channel: .release, overrides: overrides).isEnabled(Self.labs))
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
        #expect(!Self.registry.contains(Feature(index: 2, name: "other", defaults: Feature.Defaults(all: false), kind: .labs)))
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

    @Test func testBuildsRecordEarlyReadsByDefault() {
        #expect(FeatureList.Slot.recordsEarlyReadsInThisBuild)
    }

    // MARK: Cost

    @Test func aLookupAllocatesNothing() throws {
        let list = FeatureList(registry: Self.registry, channel: .nightly, overrides: FeatureOverrides(remote: ["labsThing": true]))
        let slot = FeatureList.Slot(registry: Self.registry, channel: .nightly)
        slot.install(list)
        let features = Self.registry.features
        var on = 0

        let control = MallocProbe.allocations { on += ContiguousArray(repeating: 1, count: 64).count }
        try #require((control ?? 0) > 0, "malloc_logger saw no allocation on this thread: the probe cannot measure here")

        let lookups = MallocProbe.allocations {
            for _ in 0..<10_000 {
                for feature in features {
                    if list.isEnabled(feature) { on += 1 }
                    if slot.isEnabled(feature) { on += 1 }
                }
            }
        }
        #expect(lookups == 0)
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
