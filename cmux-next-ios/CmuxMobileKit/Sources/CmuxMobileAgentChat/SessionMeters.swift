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

extension AgentChatStore {
    /// The meter's reading, once the agent reported one.
    public var contextUsage: ContextUsage? {
        guard let usage, usage.size > 0 else { return nil }
        return ContextUsage(used: usage.used, size: usage.size)
    }
}
