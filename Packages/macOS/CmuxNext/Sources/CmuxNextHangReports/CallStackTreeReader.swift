public import Foundation

/// Reads one stack out of an `MXCallStackTree.jsonRepresentation()`.
///
/// It reads five keys of each frame (`binaryName`, `binaryUUID`, `offsetIntoBinaryTextSegment`,
/// `sampleCount`, `subFrames`) and the thread flag `threadAttributed`; nothing else of the
/// payload is read. A root frame is the innermost frame and `subFrames` are its callers, so the
/// result is innermost first: the attributed thread's stack (a hang's main thread), else the
/// heaviest root, following the heaviest caller (largest `sampleCount`) at each level.
public nonisolated struct CallStackTreeReader: Sendable {
    /// One frame as MetricKit wrote it. Its text is untrusted: only ``ImageClassifier`` turns it
    /// into a ``HangReportFrame``.
    public struct RawFrame: Sendable, Equatable {
        /// MetricKit's `binaryName` (untrusted text).
        public var binaryName: String?
        /// MetricKit's `binaryUUID`.
        public var binaryUUID: String?
        /// The offset into the image's `__TEXT` segment.
        public var offset: UInt64?

        /// Makes the value from its parts.
        public init(binaryName: String?, binaryUUID: String?, offset: UInt64?) {
            self.binaryName = binaryName
            self.binaryUUID = binaryUUID
            self.offset = offset
        }
    }

    /// Makes the value from its parts.
    public init() {}

    /// The stack in `json`, innermost first and at most `limit` frames; empty when it does not parse.
    public func stack(_ json: Data, limit: Int = HangSample.maxFrames) -> [RawFrame] {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let stacks = root["callStacks"] as? [[String: Any]], !stacks.isEmpty else { return [] }
        let attributed = stacks.first { ($0["threadAttributed"] as? Bool) == true }
        let roots = (attributed ?? stacks.first)?["callStackRootFrames"] as? [[String: Any]] ?? []
        // A per-process tree (CPU exceptions) has several roots: the heaviest one.
        let candidates = attributed == nil ? stacks.flatMap { $0["callStackRootFrames"] as? [[String: Any]] ?? [] } : roots
        var frame = heaviest(candidates)
        var frames: [RawFrame] = []
        while let current = frame, frames.count < limit {
            frames.append(RawFrame(binaryName: current["binaryName"] as? String, binaryUUID: current["binaryUUID"] as? String,
                                   offset: Self.unsigned(current["offsetIntoBinaryTextSegment"])))
            frame = heaviest(current["subFrames"] as? [[String: Any]] ?? [])
        }
        return frames
    }

    private func heaviest(_ frames: [[String: Any]]) -> [String: Any]? {
        frames.max { Self.unsigned($0["sampleCount"]) ?? 0 < Self.unsigned($1["sampleCount"]) ?? 0 }
    }

    private static func unsigned(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber, number.doubleValue >= 0, number.doubleValue < 1.8e19 else { return nil }
        return number.uint64Value
    }
}
