import CmuxNextCompat
import CmuxNextHibernation
import CmuxNextSettings
import Foundation
import Testing

/// The browser hibernation plan stays the same through the `ContentDiscardPlanner` rewrite
/// (p07-memory task 017): 48 recorded browser candidate sets, each planned at the three pressures,
/// give the same due pages, next check and exemptions (by their `debug.surfaces` raw values) as the
/// planner of perf/chrome-parity d4be4a982dc, kept below as `RecordedBrowserPlan`.
@Suite struct HibernationPlannerGoldenTests {
    /// The recorded sets' indices.
    nonisolated static let indices = Array(0..<48)

    @Test(arguments: HibernationPlannerGoldenTests.indices)
    func planMatchesTheRecordedPlanner(_ index: Int) {
        let (setting, candidates) = Self.recordedSet(index)
        for pressure in [MemoryPressureLevel.normal, .warning, .critical] {
            let plan = HibernationPlanner.plan(setting, pressure: pressure, candidates: candidates)
            let recorded = RecordedBrowserPlan.make(setting, pressure: pressure, candidates: candidates)
            #expect(plan.due == recorded.due, "set \(index) at \(pressure.rawValue)")
            #expect(plan.exemptions.mapValues(\.rawValue) == recorded.exemptions, "set \(index) at \(pressure.rawValue)")
            switch (plan.nextCheck, recorded.nextCheck) {
            case (nil, nil):
                break
            case let (got?, want?):
                #expect(abs(got - want) <= 1e-9, "set \(index) at \(pressure.rawValue): next check \(got) != \(want)")
            default:
                Issue.record("set \(index) at \(pressure.rawValue): next check \(String(describing: plan.nextCheck)) != \(String(describing: recorded.nextCheck))")
            }
        }
    }

    @Test(arguments: HibernationPlannerGoldenTests.indices)
    func exemptionMatchesTheRecordedPlanner(_ index: Int) {
        let (setting, candidates) = Self.recordedSet(index)
        for candidate in candidates {
            #expect(ContentDiscardPlanner().eligibility(of: candidate, setting: setting, for: .urgent).reason?.rawValue
                    == RecordedBrowserPlan.exemption(candidate, setting: setting), "set \(index) page \(candidate.key)")
        }
    }

    /// The recorded corpus covers every setting kind and every fact the planner reads.
    @Test func theCorpusCoversEveryFact() {
        let sets = Self.indices.map { Self.recordedSet($0) }
        let pages = sets.flatMap { $0.1 }
        #expect(sets.count >= 40)
        #expect(pages.contains { $0.isPinned } && pages.contains { $0.hasDevTools } && pages.contains { $0.isCapturing })
        #expect(pages.contains { !$0.canRestore } && pages.contains { $0.showsFormSubmission } && pages.contains { $0.isDownloading })
        #expect(pages.contains { $0.hasAgentLease } && pages.contains { $0.recentlyKept } && pages.contains { $0.allowsNotifications })
        #expect(pages.contains { $0.memoryBytes != nil } && pages.contains { $0.recentFocusCount > 0 } && pages.contains { $0.host != nil })
        #expect(Set(sets.map { $0.0.hiddenMinutes }).count == 5)
    }

    /// Candidate set `index`: a fixed pseudo-random draw, the same on every run and every machine.
    static func recordedSet(_ index: Int) -> (BrowserHibernationSetting, [HibernationPlanner.Candidate]) {
        var random = SplitMix64(seed: UInt64(index) &* 0x9E37_79B9 &+ 17)
        let settings: [BrowserHibernationSetting] = [
            .fallback,
            BrowserHibernationSetting(mode: .aggressive),
            BrowserHibernationSetting(mode: .minutes(5)),
            BrowserHibernationSetting(mode: .minutes(45), exclusions: ["example.com"], includesPinnedTabs: true),
            BrowserHibernationSetting(mode: .off),
        ]
        let hidden: [Double] = [0, 5, 9.5, 30, 59, 61, 120, 300, 599, 601, 1200, 1799, 1801, 2400, 3600, 7200]
        let hosts: [String?] = [nil, "example.com", "mail.google.com", "a.b.example.com", "other.org"]
        let focus = [0, 0, 0, 1, 3, 15, 63, 100]
        let megabytes: [UInt64?] = [nil, nil, 50, 200, 800, 2000]
        let count = 1 + Int(random.next() % 12)
        let candidates = (0..<count).map { page in
            var candidate = HibernationPlanner.Candidate(
                key: "p\(page)", hiddenFor: random.pick(hidden) + Double(random.next() % 1000) / 1000,
                host: random.pick(hosts), isPinned: random.oneIn(8), hasDevTools: random.oneIn(10),
                isCapturing: random.oneIn(10), canRestore: !random.oneIn(10), showsFormSubmission: random.oneIn(12)
            )
            candidate.recentFocusCount = random.pick(focus)
            candidate.memoryBytes = random.pick(megabytes).map { $0 << 20 }
            candidate.isDownloading = random.oneIn(12)
            candidate.hasAgentLease = random.oneIn(12)
            candidate.recentlyKept = random.oneIn(4)
            candidate.allowsNotifications = random.oneIn(4)
            return candidate
        }
        return (settings[index % settings.count], candidates)
    }
}

/// A fixed pseudo-random sequence (SplitMix64): the corpus must not depend on the system generator.
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func pick<T>(_ values: [T]) -> T {
        values[Int(next() % UInt64(values.count))]
    }

    mutating func oneIn(_ n: UInt64) -> Bool {
        next() % n == 0
    }
}

/// `HibernationPlanner.plan` and `exemption` as they were at perf/chrome-parity d4be4a982dc, before
/// `ContentDiscardPlanner`, with exemptions as their raw values. Change it only with a pace or rule
/// change that is meant to change the browser plan (task 114), in the same commit.
struct RecordedBrowserPlan {
    var due: [String] = []
    var nextCheck: Double?
    var exemptions: [String: String] = [:]

    static func threshold(_ setting: BrowserHibernationSetting, pressure: MemoryPressureLevel) -> Double? {
        guard let minutes = setting.hiddenMinutes else { return nil }
        switch pressure {
        case .normal: return minutes * 60
        case .warning: return setting.mode == .aggressive ? 0 : min(minutes, 10) * 60
        case .critical: return 0
        }
    }

    static func exemption(_ candidate: HibernationPlanner.Candidate, setting: BrowserHibernationSetting) -> String? {
        if !setting.isEnabled { return "disabled" }
        if !candidate.canRestore { return "unsupported" }
        if candidate.hasAgentLease { return "agent_lease" }
        if candidate.isDownloading { return "downloading" }
        if candidate.showsFormSubmission { return "form_submission" }
        if candidate.hasDevTools { return "devtools" }
        if candidate.isCapturing { return "capturing" }
        if candidate.isPinned, !setting.includesPinnedTabs { return "pinned" }
        if setting.excludes(host: candidate.host) { return "excluded" }
        return nil
    }

    static func memoryCredit(_ bytes: UInt64?) -> Double {
        guard let bytes else { return 0 }
        return min(Double(bytes) / Double(100 << 20), 10) * 60
    }

    static func idleness(_ candidate: HibernationPlanner.Candidate, pressure: MemoryPressureLevel, timeout: Double) -> Double {
        let focus = log2(1 + Double(min(max(candidate.recentFocusCount, 0), 63))) * (1.0 / 6) * timeout
        let memory = pressure == .normal ? 0 : Self.memoryCredit(candidate.memoryBytes)
        return candidate.hiddenFor + memory - focus
    }

    static func pace(_ pressure: MemoryPressureLevel) -> (perPass: Int, interval: Double, minimumHidden: Double) {
        switch pressure {
        case .normal: return (2, 5, 0)
        case .warning: return (1, 15, 60)
        case .critical: return (3, 3, 10)
        }
    }

    static func make(_ setting: BrowserHibernationSetting, pressure: MemoryPressureLevel,
                     candidates: [HibernationPlanner.Candidate]) -> RecordedBrowserPlan {
        var plan = RecordedBrowserPlan()
        guard let threshold = Self.threshold(setting, pressure: pressure == .critical ? .warning : pressure) else {
            for candidate in candidates { plan.exemptions[candidate.key] = "disabled" }
            return plan
        }
        let pace = Self.pace(pressure)
        var ranked: [(key: String, idleness: Double, hiddenFor: Double, kept: Bool)] = []
        for candidate in candidates {
            if let exemption = Self.exemption(candidate, setting: setting) {
                plan.exemptions[candidate.key] = exemption
                continue
            }
            if candidate.allowsNotifications, pressure == .normal {
                plan.exemptions[candidate.key] = "notifications"
                continue
            }
            ranked.append((candidate.key, Self.idleness(candidate, pressure: pressure, timeout: threshold), candidate.hiddenFor,
                           pressure != .normal && candidate.recentlyKept))
        }
        ranked.sort {
            if $0.kept != $1.kept { return !$0.kept }
            return $0.idleness != $1.idleness ? $0.idleness > $1.idleness : $0.key < $1.key
        }
        let oldEnough = ranked.filter { $0.hiddenFor >= pace.minimumHidden }
        let fresh = oldEnough.filter { !$0.kept }
        var due = fresh.filter { $0.idleness >= threshold }
        if due.isEmpty, pressure != .normal { due = fresh }
        if due.isEmpty { due = oldEnough.filter { $0.idleness >= threshold } }
        if due.isEmpty, pressure != .normal { due = oldEnough }
        plan.due = due.prefix(pace.perPass).map(\.key)
        if due.count > plan.due.count || (pressure != .normal && !plan.due.isEmpty) {
            plan.nextCheck = pace.interval
        }
        let dueKeys = Set(due.map(\.key))
        for page in ranked where !dueKeys.contains(page.key) {
            let young = pace.minimumHidden - page.hiddenFor
            var wait = max(threshold - page.idleness, young)
            if pressure != .normal { wait = min(wait, max(young, pace.interval)) }
            plan.nextCheck = min(plan.nextCheck ?? .infinity, max(wait, 0.001))
        }
        return plan
    }
}
