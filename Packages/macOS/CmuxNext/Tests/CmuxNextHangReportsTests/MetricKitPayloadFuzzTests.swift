import CmuxFuzzSupport
import Foundation
import Testing
@testable import CmuxNextHangReports

/// A hang report is built from untrusted input: MetricKit's call stack tree
/// JSON, its histogram and signpost values, and the pending file the previous launch saved,
/// which a crash or a person can damage. Any input gives a bounded report (or no stack, or no
/// saved aggregate); never a trap. Seeded property tests on CmuxFuzzSupport (long mode:
/// CMUX_FUZZ_SECONDS; a failure prints its CMUX_FUZZ_SEED and CMUX_FUZZ_ITERATIONS replay).
@Suite struct MetricKitPayloadFuzzTests {
    static let treeMutator = FuzzMutator(dictionary: [
        "\"callStacks\"", "\"callStackRootFrames\"", "\"subFrames\"", "\"threadAttributed\"", "true", "false", "null",
        "\"binaryUUID\"", "\"offsetIntoBinaryTextSegment\"", "\"sampleCount\"", "\"binaryName\"",
        "18446744073709551616", "18446744073709551615", "-1", "1e308", "-0", "{", "}", "[", "]", ",", ":", "\"",
        "\"\(HangReportFixtures.appUUID)\"", "\"/usr/lib/../../Users/alice/x.dylib\"",
    ].map { Data($0.utf8) })

    static let pendingMutator = FuzzMutator(dictionary: [
        "\"counts\"", "\"stalls\"", "\"hangs\"", "\"launches\"", "\"frames\"", "\"durationMs\"", "\"cpuMs\"",
        "\"metrickit\"", "\"watchdog\"", "\"hang\"", "\"stall\"", "\"image\"", "\"offset\"", "\"uuid\"",
        "9223372036854775807", "-9223372036854775808", "{", "}", "[", "]", ",", ":", "0",
    ].map { Data($0.utf8) })

    static let trees = [Data(HangReportFixtures.hangTree.utf8), Data(HangReportFixtures.cpuTree.utf8)]
    static let uuids = [
        HangReportFixtures.appUUID, HangReportFixtures.appKitUUID, HangReportFixtures.foundationUUID,
        HangReportFixtures.imeUUID, HangReportFixtures.pluginUUID, HangReportFixtures.ghosttyUUID,
        "AAAAAAAA-BBBB-3CCC-8DDD-EEEEEEEEEEEE", "not-a-uuid", "", "3f0c9e43-7a61-3c8e-9c1a-2b7f5d0e9a11",
    ]
    static let names = [
        "AppKit", "Foundation", "libsystem_kernel.dylib", "cmux NEXT Nightly", "GhosttyKit", "SecretIME",
        "/System/Library/Frameworks/AppKit.framework/AppKit", "/System/Volumes/Data/Users/alice/x", "/usr/lib/../x",
        "cmuxa1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6", "Alices-MacBook-Pro", "", "Q3 Plans.pdf",
    ]
    static let nameAlphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789._-/ A~é")
    static let edgeInts = [Int.min, -1, 0, 1, Int.max, Int.max - 1, HistogramBucket.maxMs, HistogramBucket.maxMs + 1,
                           LaunchHistogram.maxCount, LaunchHistogram.maxCount + 1]
    static let edgeRatios: [Double?] = [
        nil, Double.nan, Double.infinity, -Double.infinity, -1, 0, 0.4, 1_000, 1_000.000_1, Double.greatestFiniteMagnitude,
    ]

    /// One input of the report pipeline, its choices read from `data` (the libFuzzer entry).
    static func oneInput(_ data: Data) throws {
        var rng = FuzzRNG(replaying: data)
        switch rng.below(5) {
        case 0: try stack(mutatedTree(&rng), limit: rng.int(in: -1...70))
        case 1: try stack(randomTree(&rng), limit: HangSample.maxFrames)
        case 2: try report(randomInputs(&rng), watchdog: randomWatchdog(&rng), wireSchema: schema(&rng))
        case 3: try pending(mutatedPending(&rng), wireSchema: schema(&rng))
        default: scan(mutatedTree(&rng))
        }
    }

    static func schema(_ rng: inout FuzzRNG) -> HangReport.WireSchema {
        rng.bool() ? .v3 : .v2
    }

    // MARK: - Inputs

    static func mutatedTree(_ rng: inout FuzzRNG) -> Data {
        guard !rng.oneIn(8), let base = rng.element(of: trees) else { return rng.bytes(512) }
        return treeMutator.mutate(base, using: &rng)
    }

    /// A call stack tree of any shape: the keys the reader reads, holding values of every JSON type.
    static func randomTree(_ rng: inout FuzzRNG) throws -> Data {
        var stacks: [Any] = []
        for _ in 0..<rng.below(4) {
            var stack: [String: Any] = [:]
            if rng.bool() { stack["threadAttributed"] = rng.oneIn(4) ? scalar(&rng) : rng.bool() as Any }
            stack["callStackRootFrames"] = rng.oneIn(8) ? scalar(&rng) : frames(&rng, depth: 0) as Any
            stacks.append(stack)
        }
        let callStacks: Any = rng.oneIn(8) ? scalar(&rng) : stacks
        let root: [String: Any] = ["callStackPerThread": rng.bool(), "callStacks": callStacks]
        try FuzzRun.check(JSONSerialization.isValidJSONObject(root), "the generated tree is JSON")
        return try JSONSerialization.data(withJSONObject: root)
    }

    /// Up to three frames at the top two levels; below them a frame has no caller one time in 8 and
    /// two one time in 16 (fewer than one on average, so a tree stays small), at most 100 levels deep.
    static func frames(_ rng: inout FuzzRNG, depth: Int) -> [Any] {
        guard depth < 100 else { return [] }
        let count = depth < 2 ? rng.below(4) : rng.oneIn(8) ? 0 : rng.oneIn(16) ? 2 : 1
        return (0..<count).map { _ in frame(&rng, depth: depth) }
    }

    static func frame(_ rng: inout FuzzRNG, depth: Int) -> Any {
        if rng.oneIn(16) { return scalar(&rng) }
        var frame: [String: Any] = [:]
        if !rng.oneIn(8) { frame["binaryUUID"] = rng.oneIn(6) ? scalar(&rng) : (rng.element(of: uuids) ?? "") as Any }
        if !rng.oneIn(8) { frame["binaryName"] = rng.oneIn(6) ? scalar(&rng) : name(&rng) as Any }
        if !rng.oneIn(8) { frame["offsetIntoBinaryTextSegment"] = number(&rng) }
        if !rng.oneIn(8) { frame["sampleCount"] = number(&rng) }
        if rng.oneIn(16) { frame["subFrames"] = scalar(&rng) } else { frame["subFrames"] = frames(&rng, depth: depth + 1) }
        return frame
    }

    static func name(_ rng: inout FuzzRNG) -> String {
        rng.bool() ? (rng.element(of: names) ?? "") : rng.text(nameAlphabet, 80)
    }

    /// A JSON number: an edge of Int, UInt64 and Double, or a small one.
    static func number(_ rng: inout FuzzRNG) -> Any {
        switch rng.below(6) {
        case 0: return Self.edgeInts[rng.below(Self.edgeInts.count)]
        case 1: return UInt64.max - UInt64(rng.below(2))
        case 2: return rng.double(in: -1e30...1e30)
        case 3: return [1.8e19, 1.9e19, -0.5, 0.5, 1_099_511_627_776, 1_099_511_627_777][rng.below(6)] as Double
        default: return rng.int(in: 0...100_000)
        }
    }

    /// Any JSON scalar (never NaN or infinity, which `JSONSerialization` cannot write).
    static func scalar(_ rng: inout FuzzRNG) -> Any {
        switch rng.below(5) {
        case 0: return NSNull()
        case 1: return rng.bool()
        case 2: return number(&rng)
        case 3: return name(&rng)
        default: return [Any]()
        }
    }

    static func int(_ rng: inout FuzzRNG) -> Int {
        switch rng.below(4) {
        case 0: edgeInts[rng.below(edgeInts.count)]
        case 1: rng.int(in: Int.min...Int.max)
        default: rng.int(in: -10...100_000)
        }
    }

    static func ratio(_ rng: inout FuzzRNG) -> Double? {
        rng.bool() ? edgeRatios[rng.below(edgeRatios.count)] : rng.double(in: -10...2_000)
    }

    static func buckets(_ rng: inout FuzzRNG) -> [HistogramBucket] {
        (0..<rng.below(40)).map { _ in HistogramBucket(lowMs: int(&rng), highMs: int(&rng), count: int(&rng)) }
    }

    static func randomInputs(_ rng: inout FuzzRNG) throws -> [MetricKitInput] {
        try (0..<rng.below(4)).map { _ in
            var metrics = HangReport.Metrics()
            metrics.hangTime = buckets(&rng)
            metrics.launchFirstDraw = buckets(&rng)
            metrics.launchResume = buckets(&rng)
            metrics.launchOptimizedFirstDraw = buckets(&rng)
            metrics.launchExtended = buckets(&rng)
            metrics.scrollHitchMsPerS = ratio(&rng)
            metrics.hitchMsPerS = ratio(&rng)
            let categories = Array(HangReportSignposts.categories.sorted()) + ["stall", "WorkspaceSecretProject", ""]
            let signposts = (0..<rng.below(80)).map { _ in
                MetricKitInput.Signpost(category: rng.element(of: categories) ?? "", name: rng.oneIn(3) ? "motion.frame" : name(&rng),
                                        count: int(&rng), buckets: buckets(&rng), hitchMsPerS: ratio(&rng))
            }
            let hangs = try (0..<rng.below(30)).map { _ in
                try MetricKitInput.Hang(durationMs: int(&rng), callStackTree: rng.bool() ? mutatedTree(&rng) : randomTree(&rng))
            }
            let cpu = try (0..<rng.below(10)).map { _ in
                try MetricKitInput.CPUException(cpuMs: int(&rng), sampledMs: int(&rng),
                                                callStackTree: rng.bool() ? mutatedTree(&rng) : randomTree(&rng))
            }
            return MetricKitInput(hangs: hangs, cpuExceptions: cpu, metrics: metrics, signposts: signposts)
        }
    }

    /// The collector's side: stall counts, kept samples with frames from any addresses, and launches.
    static func randomWatchdog(_ rng: inout FuzzRNG) -> StallAggregate {
        let builder = HangReportFixtures.builder()
        var aggregate = StallAggregate()
        for _ in 0..<rng.below(40) { aggregate.count(durationMs: int(&rng)) }
        for _ in 0..<rng.below(20) {
            let addresses = (0..<rng.below(80)).map { _ in
                rng.bool() ? (rng.element(of: HangReportFixtures.watchdogAddresses) ?? 0) : UInt(truncatingIfNeeded: rng.next())
            }
            aggregate.keep(HangSample(source: .watchdog, kind: rng.bool() ? .hang : .stall, durationMs: int(&rng),
                                      cpuMs: rng.bool() ? int(&rng) : nil, frames: builder.frames(addresses: addresses)))
        }
        for _ in 0..<rng.below(6) {
            let temperature = rng.element(of: LaunchTemperature.allCases) ?? .warm
            let reason = rng.element(of: LaunchCompletionReason.allCases) ?? .visiblePaneLoadedIdle
            aggregate.record(launch: LaunchAggregate.Record(
                temperature: temperature, interrupted: rng.oneIn(4),
                firstFrame: rng.bool() ? Duration.milliseconds(rng.int(in: -1_000...200_000_000)) : nil,
                liveContent: rng.bool() ? Duration.milliseconds(rng.int(in: -1_000...200_000_000)) : nil,
                startupComplete: Duration.milliseconds(rng.int(in: -1_000...200_000_000)), reason: reason))
        }
        return aggregate
    }

    /// A pending file the previous launch saved, after a mutation pass, or random bytes.
    static func mutatedPending(_ rng: inout FuzzRNG) throws -> Data {
        guard !rng.oneIn(8) else { return rng.bytes(512) }
        var seedRNG = FuzzRNG(seed: 0x2907)
        let saved = try JSONEncoder().encode(randomWatchdog(&seedRNG))
        return pendingMutator.mutate(saved, using: &rng)
    }

    // MARK: - Properties

    /// The reader: at most `limit` frames, the same as the builder's classified frames.
    static func stack(_ json: Data, limit: Int) throws {
        let raw = CallStackTreeReader().stack(json, limit: limit)
        try FuzzRun.check(raw.count <= max(limit, 0), "\(raw.count) frames for a limit of \(limit)")
        let frames = HangReportFixtures.builder().frames(json)
        try FuzzRun.check(frames.count <= HangSample.maxFrames, "\(frames.count) classified frames")
        for frame in frames { try checkFrame(frame) }
    }

    static func report(_ inputs: [MetricKitInput], watchdog: StallAggregate, wireSchema: HangReport.WireSchema) throws {
        let built = HangReportFixtures.builder(wireSchema: wireSchema)
            .build(context: HangReportFixtures.context(), watchdog: watchdog, metricKit: inputs)
        try checkReport(built, classifiedFrames: true)
    }

    /// A saved aggregate decodes to one that merges and reports, or does not decode at all.
    static func pending(_ bytes: Data, wireSchema: HangReport.WireSchema) throws {
        guard let saved = try? JSONDecoder().decode(StallAggregate.self, from: bytes) else { return }
        try FuzzRun.check(saved.counts.count == StallAggregate.bucketEdgesMs.count && saved.counts.allSatisfy { $0 >= 0 },
                          "a saved aggregate has \(saved.counts.count) counts")
        try checkHistogram(saved.histogram, "the saved histogram")
        var live = StallAggregate()
        live.count(durationMs: 300)
        live.merge(saved)
        live.count(durationMs: 300)
        try FuzzRun.check(live.hangs.count <= StallAggregate.maxSamples && live.stalls.count <= StallAggregate.maxSamples,
                          "\(live.hangs.count) hangs and \(live.stalls.count) stalls kept")
        // The saved frames are whatever the file says; the privacy scan before a send judges them.
        let built = HangReportFixtures.builder(wireSchema: wireSchema)
            .build(context: HangReportFixtures.context(), watchdog: live, metricKit: [])
        try checkReport(built, classifiedFrames: false)
    }

    static func scan(_ json: Data) {
        _ = PrivacyLeakScanner(forbiddenTerms: HangReportFixtures.forbiddenTerms).findings(in: json)
    }

    static func checkFrame(_ frame: HangReportFrame) throws {
        guard !frame.isOther else {
            return try FuzzRun.check(frame.uuid == nil && frame.offset == nil, "an other frame names no image")
        }
        try FuzzRun.check(frame.image.range(of: ImageClassifier.namePattern, options: .regularExpression) != nil,
                          "a named frame's image fits the name pattern")
        try FuzzRun.check(frame.uuid.map(ImageClassifier.isUUID) == true, "a named frame has a UUID")
        try FuzzRun.check((frame.offset ?? .max) <= ImageClassifier.maxOffset, "a named frame's offset is in range")
        let lowered = frame.image.lowercased()
        let terms = ImageClassifier.normalizedTerms(HangReportFixtures.forbiddenTerms)
        try FuzzRun.check(!terms.contains { lowered.contains($0) }, "a named frame holds no personal term")
    }

    static func checkHistogram(_ buckets: [HistogramBucket], _ what: String) throws {
        try FuzzRun.check(buckets.count <= HistogramBucket.maxBuckets, "\(what): \(buckets.count) buckets")
        for bucket in buckets {
            try FuzzRun.check(bucket.count > 0 && 0 <= bucket.lowMs && bucket.lowMs <= bucket.highMs
                              && bucket.highMs <= HistogramBucket.maxMs, "\(what): bucket \(bucket)")
        }
    }

    static func checkRatio(_ ratio: Double?, _ what: String) throws {
        try FuzzRun.check(ratio.map { $0.isFinite && 0 <= $0 && $0 <= 1_000 } ?? true, "\(what): \(String(describing: ratio))")
    }

    static func checkReport(_ report: HangReport, classifiedFrames: Bool) throws {
        try FuzzRun.check(report.hangs.count <= HangReport.maxHangs, "\(report.hangs.count) hangs")
        try FuzzRun.check(report.cpuExceptions.count <= HangReport.maxCPUExceptions, "\(report.cpuExceptions.count) CPU exceptions")
        try FuzzRun.check(report.intervals.count <= HangReport.maxIntervals, "\(report.intervals.count) intervals")
        try FuzzRun.check(zip(report.hangs, report.hangs.dropFirst()).allSatisfy { $0.durationMs >= $1.durationMs },
                          "hangs are longest first")
        try FuzzRun.check(report.hangs.allSatisfy { $0.durationMs >= 0 && ($0.cpuMs ?? 0) >= 0 }, "hang times are nonnegative")
        try FuzzRun.check(report.cpuExceptions.allSatisfy { $0.cpuMs >= 0 && $0.sampledMs >= 0 }, "CPU times are nonnegative")
        for frames in report.hangs.map(\.frames) + report.cpuExceptions.map(\.frames) {
            try FuzzRun.check(frames.count <= HangSample.maxFrames, "a stack of \(frames.count) frames")
            if classifiedFrames { for frame in frames { try checkFrame(frame) } }
        }
        let metrics = report.metrics
        try checkHistogram(report.stallHistogram, "stallHistogram")
        try checkHistogram(metrics.hangTime, "hangTime")
        try checkHistogram(metrics.launchFirstDraw, "launchFirstDraw")
        try checkHistogram(metrics.launchResume, "launchResume")
        try checkHistogram(metrics.launchOptimizedFirstDraw, "launchOptimizedFirstDraw")
        try checkHistogram(metrics.launchExtended, "launchExtended")
        try checkRatio(metrics.scrollHitchMsPerS, "scrollHitchMsPerS")
        try checkRatio(metrics.hitchMsPerS, "hitchMsPerS")
        for interval in report.intervals {
            try FuzzRun.check(HangReportSignposts.allows(category: interval.category, name: interval.name),
                              "only allowlisted intervals")
            try FuzzRun.check(interval.count >= 0, "an interval count of \(interval.count)")
            try checkHistogram(interval.buckets, "interval")
            try checkRatio(interval.hitchMsPerS, "interval hitchMsPerS")
        }
        try FuzzRun.check(report.schema == HangReport.WireSchema.v3.rawValue || report.launches == nil, "schema 2 carries no launches")
        for histogram in (report.launches?.launchFirstFrame ?? []) + (report.launches?.launchStartupComplete ?? [])
            + (report.launches?.launchLiveContent ?? []) {
            try FuzzRun.check((1...LaunchHistogram.maxCount).contains(histogram.count), "a launch count of \(histogram.count)")
            try checkHistogram(histogram.buckets, "launch")
        }
        let body = try HangReport.encoder.encode(report)
        _ = try JSONDecoder().decode(HangReport.self, from: body)
        scan(body)
    }

    // MARK: - Regressions (each trapped before p10-stability-029)

    /// Two deliveries' counts of one bucket, and of one signpost, summed past `Int.max`.
    @Test func countsPastIntMaxStopThere() throws {
        var metrics = HangReport.Metrics()
        metrics.hangTime = [HistogramBucket(lowMs: 0, highMs: 100, count: .max)]
        let signpost = MetricKitInput.Signpost(category: "motion", name: "motion.frame", count: .max,
                                               buckets: [HistogramBucket(lowMs: 0, highMs: 10, count: .max)])
        let delivery = MetricKitInput(metrics: metrics, signposts: [signpost])
        let report = HangReportFixtures.builder()
            .build(context: HangReportFixtures.context(), watchdog: StallAggregate(), metricKit: [delivery, delivery])
        #expect(report.metrics.hangTime == [HistogramBucket(lowMs: 0, highMs: 100, count: .max)])
        #expect(report.intervals.map(\.count) == [.max])
        #expect(report.intervals.first?.buckets == [HistogramBucket(lowMs: 0, highMs: 10, count: .max)])
    }

    /// A pending file with nine counts (index 8 has no bucket edge) and a count at `Int.max`.
    @Test func aDamagedPendingFileMergesWithinBounds() throws {
        let counts = [Int.max, -4, 0, 0, 0, 0, 0, 0, 1].map(String.init).joined(separator: ",")
        let frames = Array(repeating: #"{"image":"AppKit","uuid":"\#(HangReportFixtures.appKitUUID)","offset":1}"#, count: 70)
        let hang = #"{"source":"watchdog","kind":"hang","durationMs":-30,"cpuMs":-1,"frames":[\#(frames.joined(separator: ","))]}"#
        let json = #"{"counts":[\#(counts)],"stalls":[],"hangs":[\#(hang)]}"#
        let saved = try JSONDecoder().decode(StallAggregate.self, from: Data(json.utf8))
        #expect(saved.counts == [Int.max, 0, 0, 0, 0, 0, 0, 0])
        #expect(saved.histogram == [HistogramBucket(lowMs: 50, highMs: 100, count: .max)])
        #expect(saved.hangs.first?.durationMs == 0)
        #expect(saved.hangs.first?.cpuMs == 0)
        #expect(saved.hangs.first?.frames.count == HangSample.maxFrames)
        var live = StallAggregate()
        live.count(durationMs: 60)
        live.merge(saved)
        live.count(durationMs: 60)
        #expect(live.counts.first == .max)
    }

    /// The saved form of a sample is unchanged: what a pending file held still decodes to the same value.
    @Test func aSavedAggregateDecodesToItself() throws {
        var rng = FuzzRNG(seed: 0x2908)
        let aggregate = Self.randomWatchdog(&rng)
        let decoded = try JSONDecoder().decode(StallAggregate.self, from: JSONEncoder().encode(aggregate))
        #expect(decoded == aggregate)
    }

    // MARK: - Seeded runs

    @Test func mutatedCallStackTreesGiveBoundedStacks() throws {
        let run = try FuzzRun("MetricKitPayload.mutatedTree", seed: 0x2911, iterations: 2_000)
        try run.forEachInput(run.corpus(seeds: Self.trees), mutator: Self.treeMutator) { json in
            try Self.stack(json, limit: HangSample.maxFrames)
            try Self.stack(json, limit: 3)
            Self.scan(json)
        }
    }

    @Test func callStackTreesOfAnyShapeGiveBoundedStacks() throws {
        try FuzzRun("MetricKitPayload.randomTree", seed: 0x2912, iterations: 1_500).forEach { rng in
            try Self.stack(Self.randomTree(&rng), limit: rng.int(in: -1...70))
        }
    }

    @Test func anyDeliveriesBuildABoundedReport() throws {
        try FuzzRun("MetricKitPayload.report", seed: 0x2913, iterations: 400).forEach { rng in
            try Self.report(Self.randomInputs(&rng), watchdog: Self.randomWatchdog(&rng), wireSchema: Self.schema(&rng))
        }
    }

    @Test func pendingFilesDecodeToBoundedAggregatesOrNothing() throws {
        let run = try FuzzRun("MetricKitPayload.pending", seed: 0x2914, iterations: 1_000)
        var seedRNG = FuzzRNG(seed: 0x2907)
        let seed = try JSONEncoder().encode(Self.randomWatchdog(&seedRNG))
        try run.forEachInput(run.corpus(seeds: [seed]), mutator: Self.pendingMutator) { bytes in
            try Self.pending(bytes, wireSchema: .v3)
        }
    }

    @Test func oneInputTakesAnyBytes() throws {
        let run = try FuzzRun("MetricKitPayload.oneInput", seed: 0x2915, iterations: 256)
        // Choice tapes: one per branch of `oneInput` (0 and 4 on each fixture tree, 3 on a mutated pending file).
        let branches: [[UInt8]] = [[0, 1, 0], [0, 1, 1], [1, 3], [2, 3], [3, 1], [4, 1, 0], [4, 1, 1]]
        try run.forEachInput(run.corpus(seeds: branches.map { Data($0) }), Self.oneInput)
    }
}
