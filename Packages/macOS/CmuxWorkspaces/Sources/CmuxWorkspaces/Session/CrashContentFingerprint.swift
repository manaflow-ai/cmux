import CryptoKit
import Foundation

/// Compares complete, stable snapshot values within a fixed encoding budget.
///
/// A counting encoder bounds the JSON allocation before the exact sorted-key
/// bytes are hashed. Values that cannot be fully compared return nil; sampled
/// content is never accepted as equality evidence.
public struct CrashContentFingerprint: Sendable {
    private var remainingBytes: Int
    private var remainingNodes = 1_000_000
    private let maximumValueBytes: Int
    private var exhausted = false

    /// Creates a budget local to one restore operation.
    /// - Parameters:
    ///   - maximumBytes: Cumulative upper bound on all encoded content bytes.
    ///   - maximumValueBytes: Upper bound for one complete encoded value.
    public nonisolated init(
        maximumBytes: Int = 32 * 1024 * 1024,
        maximumValueBytes: Int = 4 * 1024 * 1024
    ) {
        remainingBytes = max(0, maximumBytes)
        self.maximumValueBytes = max(0, maximumValueBytes)
    }

    /// Hashes the exact sorted-key JSON representation of an immutable snapshot value.
    /// - Parameter value: A stable Codable value whose encoding has no side effects.
    /// - Returns: A complete SHA-256 digest, or nil on any encoding or budget failure.
    public nonisolated mutating func fingerprint<Value: Encodable>(_ value: Value) -> String? {
        guard !exhausted else { return nil }
        let budget = CrashEncodingBudget(
            maximumBytes: min(remainingBytes, maximumValueBytes), maximumNodes: remainingNodes
        )
        do {
            try CrashCountingEncoder(budget: budget).encode(value)
            guard !budget.failed else { exhausted = true; return nil }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(value)
            guard data.count <= budget.usedBytes else { exhausted = true; return nil }
            remainingBytes -= budget.usedBytes
            remainingNodes -= budget.usedNodes
            return Data(SHA256.hash(data: data)).base64EncodedString()
        } catch {
            exhausted = true
            return nil
        }
    }
}
