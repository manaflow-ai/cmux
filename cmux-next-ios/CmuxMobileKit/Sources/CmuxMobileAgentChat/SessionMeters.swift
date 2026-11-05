import Foundation

/// The context window in use (`usage_update`), as the ACP web UI's meter shows it.
public struct ContextUsage: Hashable, Sendable {
    public var used: Int
    public var size: Int

    public init(used: Int, size: Int) {
        self.used = used
        self.size = size
    }

    /// 0...1 (0 when the size is unknown).
    public var fraction: Double {
        guard size > 0 else { return 0 }
        return min(1, max(0, Double(used) / Double(size)))
    }

    /// Whole percent used, e.g. 24.
    public var percent: Int { Int((fraction * 100).rounded()) }

    /// Nearly full: the ring turns to the warning tint (80 % and up).
    public var isNearlyFull: Bool { fraction >= 0.8 }

    /// "48K of 200K tokens".
    public var tokensLabel: String { "\(Self.compact(used)) of \(Self.compact(size)) tokens" }

    static func compact(_ value: Int) -> String {
        switch value {
        case ..<1_000: return "\(value)"
        case ..<1_000_000:
            let k = Double(value) / 1_000
            return k < 10 && k.rounded() != k ? String(format: "%.1fK", k) : "\(Int(k.rounded()))K"
        default:
            let m = Double(value) / 1_000_000
            return m.rounded() == m ? "\(Int(m))M" : String(format: "%.1fM", m)
        }
    }
}

/// The running turn's plan, pinned above the composer: `3 / 5` and the step in progress.
public struct PlanProgress: Hashable, Sendable {
    public var completed: Int
    public var total: Int
    /// The step in progress, else the next pending one.
    public var current: String?

    public init?(entries: [ACPPlanEntry]) {
        guard !entries.isEmpty else { return nil }
        completed = entries.count { $0.status == .completed }
        total = entries.count
        current = (entries.first { $0.status == .inProgress } ?? entries.first { $0.status == .pending })?.content
    }

    public var isDone: Bool { completed == total }

    /// "3 / 5".
    public var countLabel: String { "\(completed) / \(total)" }
}

extension AgentChatStore {
    /// The meter's reading, once the agent reported one.
    public var contextUsage: ContextUsage? {
        guard let usage, usage.size > 0 else { return nil }
        return ContextUsage(used: usage.used, size: usage.size)
    }

    /// The latest plan of the running turn (nil when idle or planless).
    public var runningPlan: PlanProgress? {
        runningPlanEntries.flatMap(PlanProgress.init(entries:))
    }

}
