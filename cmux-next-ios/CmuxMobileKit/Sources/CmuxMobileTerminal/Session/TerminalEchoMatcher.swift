import Foundation

/// Matches typed bytes with their echo in the session output (G-08, the
/// real-link echo probe of ACCEPTANCE.md M-ECHO). Pure: the DEBUG probe
/// (`TerminalDevProbe`) feeds it the bytes sent and the batches handed to
/// Ghostty, and stamps the frame that shows them.
///
/// Each printable byte sent waits in order; an output batch echoes the
/// oldest waiting byte when it contains that byte, after the earlier echoes.
/// A byte not echoed within `expiry` is dropped and counted as lost. Under a
/// flood, type a byte the flood never prints (`~`, `^`; `stream20` prints
/// neither), or the match can come early.
public struct TerminalEchoMatcher: Sendable, Equatable {
    public struct Key: Sendable, Equatable {
        public var byte: UInt8
        public var sentAt: TimeInterval
    }

    public static let expiry: TimeInterval = 5

    public private(set) var waiting: [Key] = []
    public private(set) var lost = 0

    public init() {}

    /// Bytes the person typed; only printable ASCII is probed.
    public mutating func sent(_ data: Data, at time: TimeInterval) {
        for byte in data where (0x21...0x7E).contains(byte) {
            waiting.append(Key(byte: byte, sentAt: time))
        }
    }

    /// An output batch: the keys it echoes, oldest first.
    public mutating func output(_ data: Data, at time: TimeInterval) -> [Key] {
        let before = waiting.count
        waiting.removeAll { time - $0.sentAt > Self.expiry }
        lost += before - waiting.count
        var echoed: [Key] = []
        var index = data.startIndex
        while let key = waiting.first, index < data.endIndex {
            guard let found = data[index...].firstIndex(of: key.byte) else { break }
            echoed.append(key)
            waiting.removeFirst()
            index = data.index(after: found)
        }
        return echoed
    }
}

/// Percentiles of echo latencies in milliseconds (nearest rank).
public struct TerminalEchoStats: Sendable, Equatable, Codable {
    public var n: Int
    public var p50: Double
    public var p95: Double
    public var p99: Double
    public var max: Double

    public init(_ samples: [Double]) {
        let sorted = samples.sorted()
        func rank(_ p: Double) -> Double {
            guard !sorted.isEmpty else { return 0 }
            return sorted[min(sorted.count - 1, Int((p * Double(sorted.count)).rounded(.up)) - 1)]
        }
        n = sorted.count
        p50 = rank(0.5)
        p95 = rank(0.95)
        p99 = rank(0.99)
        max = sorted.last ?? 0
    }
}
