import Atomics
import CmuxNextFeatures
import Testing

/// FeatureParam handles and the FeatureParamList snapshot (base::FeatureParam,
/// p12-perf-process.md section 3.9): defaults, remote and local values,
/// bounds, rejections and the cost of a read.
struct FeatureParamTests {
    private static let off = feature(0, "offThing", on: false, params: [
        FeatureParamSpec(name: "limit", description: "A limit.", value: .int(default: 10, min: 1, max: 100)),
    ])
    private static let tuned = feature(1, "tunedThing", on: true, params: [
        FeatureParamSpec(name: "retries", description: "Retries.", value: .int(default: 2, min: 0, max: 8)),
        FeatureParamSpec(name: "scale", description: "Scale.", value: .double(default: 1.5, min: 1.0, max: 2.0)),
        FeatureParamSpec(name: "deadline", description: "Deadline.", value: .duration(default: 0.05, min: 0, max: 1)),
        FeatureParamSpec(name: "eager", description: "Eager.", value: .bool(default: false)),
    ])
    private static let registry = FeatureRegistry([off, tuned])

    private static let limit = FeatureParam<Int>(off, "limit", in: registry)
    private static let retries = FeatureParam<Int>(tuned, "retries", in: registry)
    private static let scale = FeatureParam<Double>(tuned, "scale", in: registry)
    private static let deadline = FeatureParam<Duration>(tuned, "deadline", in: registry)
    private static let deadlineSeconds = FeatureParam<Double>(tuned, "deadline", in: registry)
    private static let eager = FeatureParam<Bool>(tuned, "eager", in: registry)

    private static func feature(_ index: Int, _ name: String, on: Bool, params: [FeatureParamSpec]) -> Feature {
        Feature(
            index: index,
            name: name,
            owner: "PL-test",
            description: "A test feature.",
            kind: .perfPath,
            process: .app,
            chromiumFeature: nil,
            defaults: FeatureDefaults(all: on),
            expires: "2026-12-20",
            params: params,
            stories: ["dev-loop"],
            sticky: false,
            runtimeMutable: false
        )
    }

    private static func params(
        channel: Feature.Channel = .nightly,
        enabled: Set<String> = [],
        remote: [String: [String: String]] = [:],
        local: (any FeatureParamLocalOverrideProvider)? = nil,
        report: (FeatureParamList.Rejection) -> Void = { _ in }
    ) -> FeatureParamList {
        let features = FeatureList(registry: registry, channel: channel, overrides: FeatureOverrides(environmentEnabled: enabled))
        return FeatureParamList(features: features, remote: remote, local: local, report: report)
    }

    // MARK: Handles

    @Test func aHandleFindsItsSlotAmongEveryParamOfTheRegistry() {
        #expect(Self.limit.slot == 0)
        #expect(Self.retries.slot == 1)
        #expect(Self.eager.slot == 4)
        #expect(Self.eager.index == 3)
        #expect(Self.deadline.spec?.value == .duration(default: 0.05, min: 0, max: 1))
        #expect(Self.deadline.declaredDefault == .seconds(0.05))
        #expect(Self.deadlineSeconds.declaredDefault == 0.05)
        #expect(Self.limit.declaredDefault == 10)
        #expect(!Self.eager.declaredDefault)
    }

    @Test func aScalarConvertsOnlyToItsOwnType() {
        #expect(Int(featureParam: .int(3)) == 3)
        #expect(Int(featureParam: .double(3)) == nil)
        #expect(Double(featureParam: .double(0.5)) == 0.5)
        #expect(Duration(featureParam: .double(0.5)) == .seconds(0.5))
        #expect(Duration(featureParam: .bool(true)) == nil)
        #expect(Bool(featureParam: .bool(true)) == true)
        #expect(Bool(featureParam: .int(1)) == nil)
    }

    @Test func aHandleTypeMatchesTheDeclaredType() {
        #expect(Int.accepts(.int(default: 0, min: 0, max: 1)))
        #expect(!Int.accepts(.double(default: 0, min: 0, max: 1)))
        #expect(Double.accepts(.double(default: 0, min: 0, max: 1)))
        #expect(Double.accepts(.duration(default: 0, min: 0, max: 1)))
        #expect(!Double.accepts(.int(default: 0, min: 0, max: 1)))
        #expect(Duration.accepts(.duration(default: 0, min: 0, max: 1)))
        #expect(!Duration.accepts(.double(default: 0, min: 0, max: 1)))
        #expect(Bool.accepts(.bool(default: true)))
        #expect(!Bool.accepts(.int(default: 0, min: 0, max: 1)))
    }

    // MARK: Values

    @Test func aMissingValueReadsTheDefault() {
        var reported: [FeatureParamList.Rejection] = []
        let list = Self.params(remote: ["tunedThing": ["scale": "1.75"]], report: { reported.append($0) })
        #expect(list.value(Self.retries) == 2)
        #expect(list.value(Self.deadline) == .seconds(0.05))
        #expect(list.value(Self.deadlineSeconds) == 0.05)
        #expect(!list.value(Self.eager))
        #expect(list.resolution(of: Self.retries) == FeatureParamList.Resolution(value: .int(2), source: .channelDefault))
        #expect(list.value(Self.scale) == 1.75)
        #expect(reported.isEmpty)
        #expect(list.rejections.isEmpty)
    }

    @Test func remoteValuesApplyToAFeatureThatIsOn() {
        let list = Self.params(remote: ["tunedThing": ["retries": "5", "scale": "2", "deadline": "0.25", "eager": "true"]])
        #expect(list.value(Self.retries) == 5)
        #expect(list.value(Self.scale) == 2.0)
        #expect(list.value(Self.deadline) == .seconds(0.25))
        #expect(list.value(Self.eager))
        #expect(list.resolution(of: Self.deadline) == FeatureParamList.Resolution(value: .double(0.25), source: .remote))
    }

    @Test func theBoundsAreInclusive() {
        let low = Self.params(remote: ["tunedThing": ["retries": "0", "scale": "1", "deadline": "0"]])
        #expect(low.value(Self.retries) == 0)
        #expect(low.value(Self.scale) == 1.0)
        #expect(low.value(Self.deadline) == .zero)
        let high = Self.params(remote: ["tunedThing": ["retries": "8", "scale": "2.0", "deadline": "1"]])
        #expect(high.value(Self.retries) == 8)
        #expect(high.value(Self.deadline) == .seconds(1))
        #expect(low.rejections.isEmpty && high.rejections.isEmpty)
    }

    @Test func anOutOfRangeValueIsRejectedAndLogged() {
        var reported: [FeatureParamList.Rejection] = []
        let list = Self.params(remote: ["tunedThing": ["retries": "9", "deadline": "5", "scale": "0.5"]], report: { reported.append($0) })
        #expect(list.value(Self.retries) == 2)
        #expect(list.value(Self.deadline) == .seconds(0.05))
        #expect(list.value(Self.scale) == 1.5)
        #expect(list.resolution(of: Self.deadline)?.source == .channelDefault)
        #expect(reported == list.rejections)
        #expect(reported.map(\.description) == [
            "tunedThing.retries=\"9\" source=remote: outside 0...8",
            "tunedThing.scale=\"0.5\" source=remote: outside 1.0...2.0",
            "tunedThing.deadline=\"5\" source=remote: outside 0.0...1.0",
        ])
    }

    @Test(arguments: [
        ("retries", "1.5"), ("retries", ""), ("retries", " 3"), ("retries", "99999999999999999999"),
        ("scale", "nan"), ("scale", "inf"), ("scale", "fast"),
        ("deadline", "-inf"), ("deadline", "50ms"),
        ("eager", "yes"), ("eager", "1"), ("eager", "TRUE"),
    ])
    func aMalformedValueIsRejected(param: String, text: String) {
        let list = Self.params(remote: ["tunedThing": [param: text]])
        #expect(list.rejections.count == 1)
        #expect(list.rejections.first?.param == param)
        #expect(list.rejections.first?.text == text)
        guard case .malformed = list.rejections.first?.reason else {
            Issue.record("\(param)=\(text) gave \(String(describing: list.rejections.first?.reason))")
            return
        }
        #expect(list.entries.allSatisfy { $0.resolution.source == .channelDefault })
    }

    @Test func undeclaredNamesAreRejectedAndLogged() {
        var reported: [FeatureParamList.Rejection] = []
        let list = Self.params(
            remote: ["tunedThing": ["retries": "3", "ghost": "1"], "goneThing": ["b": "2", "a": "1"]],
            report: { reported.append($0) }
        )
        #expect(list.value(Self.retries) == 3)
        #expect(reported.map(\.description) == [
            "goneThing.a=\"1\" source=remote: unknown feature",
            "goneThing.b=\"2\" source=remote: unknown feature",
            "tunedThing.ghost=\"1\" source=remote: unknown param",
        ])
    }

    @Test func aFeatureThatIsOffReadsItsDefaults() {
        let list = Self.params(remote: ["offThing": ["limit": "50"]])
        #expect(list.value(Self.limit) == 10)
        #expect(list.resolution(of: Self.limit)?.source == .channelDefault)
        #expect(list.rejections.isEmpty)
        #expect(Self.params(enabled: ["offThing"], remote: ["offThing": ["limit": "50"]]).value(Self.limit) == 50)
    }

    @Test func aBadRemoteValueIsReportedWhileItsFeatureIsOff() {
        let list = Self.params(remote: ["offThing": ["limit": "0"]])
        #expect(list.rejections.map(\.description) == ["offThing.limit=\"0\" source=remote: outside 1...100"])
    }

    // MARK: Local overrides

    @Test(arguments: [Feature.Channel.dev, .nightly])
    func aLocalValueBeatsTheRemoteOne(channel: Feature.Channel) {
        let local = RecordingParamOverrides(["tunedThing.retries": "7"])
        let list = Self.params(channel: channel, remote: ["tunedThing": ["retries": "4", "scale": "1.25"]], local: local)
        #expect(list.resolution(of: Self.retries) == FeatureParamList.Resolution(value: .int(7), source: .local))
        #expect(list.resolution(of: Self.scale) == FeatureParamList.Resolution(value: .double(1.25), source: .remote))
    }

    @Test func aLocalValueIsIgnoredInRelease() {
        let local = RecordingParamOverrides(["tunedThing.retries": "7"])
        let list = Self.params(channel: .release, remote: ["tunedThing": ["retries": "4"]], local: local)
        #expect(list.resolution(of: Self.retries) == FeatureParamList.Resolution(value: .int(4), source: .remote))
        #expect(local.asked.load(ordering: .relaxed) == 0)
    }

    @Test func aRejectedLocalValueFallsBackToTheRemoteOne() {
        let local = RecordingParamOverrides(["tunedThing.retries": "70"])
        let list = Self.params(channel: .dev, remote: ["tunedThing": ["retries": "4"]], local: local)
        #expect(list.resolution(of: Self.retries) == FeatureParamList.Resolution(value: .int(4), source: .remote))
        #expect(list.rejections.map(\.description) == ["tunedThing.retries=\"70\" source=local: outside 0...8"])
    }

    @Test func theLocalProviderIsNotAskedForAFeatureThatIsOff() {
        let local = RecordingParamOverrides(["offThing.limit": "50"])
        let list = Self.params(channel: .dev, local: local)
        #expect(list.value(Self.limit) == 10)
        #expect(local.asked.load(ordering: .relaxed) == 4)
    }

    // MARK: Cost and reporting

    /// Inputs are read and checked once, when the snapshot is built; a read
    /// is one load of the cached value and asks no input again.
    @Test func eachInputIsReadOnceAndAReadAsksNothing() {
        let local = RecordingParamOverrides(["tunedThing.scale": "1.25", "tunedThing.eager": "maybe"])
        var reports = 0
        let list = Self.params(channel: .nightly, remote: ["tunedThing": ["retries": "3"]], local: local, report: { _ in reports += 1 })
        #expect(local.asked.load(ordering: .relaxed) == 4)
        #expect(reports == 1)
        var sum = 0.0
        for _ in 0..<10_000 {
            sum += list.value(Self.scale) + Double(list.value(Self.retries))
        }
        #expect(sum == 10_000 * (1.25 + 3))
        #expect(local.asked.load(ordering: .relaxed) == 4)
        #expect(reports == 1)
        #expect(list.rejections.count == 1)
    }

    @Test func entriesListEveryParamInRegistryOrder() {
        let list = Self.params(remote: ["tunedThing": ["deadline": "0.5"]])
        let described = list.entries.map { "\($0.feature.name).\($0.spec.name) \($0.resolution)" }
        #expect(described == [
            "offThing.limit 10 source=default",
            "tunedThing.retries 2 source=default",
            "tunedThing.scale 1.5 source=default",
            "tunedThing.deadline 0.5 source=remote",
            "tunedThing.eager false source=default",
        ])
    }

    @Test func theDefaultReportKeepsTheRejection() {
        let features = FeatureList(registry: Self.registry, channel: .dev)
        let list = FeatureParamList(features: features, remote: ["tunedThing": ["retries": "-1"]])
        #expect(list.rejections.map(\.reason) == [.outOfRange(min: "0", max: "8")])
        #expect(list.value(Self.retries) == 2)
    }
}

/// A local param provider keyed `feature.param` that counts how often it is asked.
private final class RecordingParamOverrides: FeatureParamLocalOverrideProvider {
    let values: [String: String]
    let asked = ManagedAtomic<Int>(0)

    init(_ values: [String: String]) { self.values = values }

    func localOverride(for spec: FeatureParamSpec, of feature: Feature) -> String? {
        asked.wrappingIncrement(ordering: .relaxed)
        return values["\(feature.name).\(spec.name)"]
    }
}
