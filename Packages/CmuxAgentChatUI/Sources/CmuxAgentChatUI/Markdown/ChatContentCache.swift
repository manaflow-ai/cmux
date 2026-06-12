import Foundation
import SwiftUI

/// Bounded main-actor cache for the non-markdown row-body work that is too
/// expensive to repeat per lazy re-materialization: ANSI-sanitized terminal
/// lines and prose segment splits.
///
/// Same design constraints as ``ChatMarkdownRenderer``: deliberately not
/// `@Observable` (environment passage must not invalidate rows), keys
/// include the content hash so streaming updates re-compute only the
/// changing message.
@MainActor
public final class ChatContentCache {
    private var lines: [String: [String]] = [:]
    private var segments: [String: [ChatProseSegment]] = [:]
    private var blocks: [String: [ChatTextBlock]] = [:]
    private var lineOrder: [String] = []
    private var segmentOrder: [String] = []
    private var blockOrder: [String] = []
    private let capacity: Int

    /// Creates a cache.
    ///
    /// - Parameter capacity: Maximum entries per kind before the oldest
    ///   are evicted.
    public init(capacity: Int = 400) {
        self.capacity = capacity
    }

    /// ANSI-sanitized output split into display lines, cached.
    ///
    /// - Parameters:
    ///   - messageID: Stable identity of the owning message.
    ///   - output: The raw captured output.
    /// - Returns: Display lines.
    public func sanitizedLines(messageID: String, output: String) -> [String] {
        let key = "\(messageID)-\(output.hashValue)"
        if let cached = lines[key] { return cached }
        let cleaned = ChatANSISanitizer().sanitized(output)
        let result = cleaned.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.count >= capacity, let oldest = lineOrder.first {
            lines[oldest] = nil
            lineOrder.removeFirst()
        }
        lines[key] = result
        lineOrder.append(key)
        return result
    }

    /// Prose text split into text/code segments, cached.
    ///
    /// - Parameters:
    ///   - messageID: Stable identity of the owning message.
    ///   - text: The prose source.
    /// - Returns: Render segments.
    /// Block-level elements of a text segment, cached.
    ///
    /// - Parameters:
    ///   - messageID: Stable identity of the owning segment.
    ///   - text: The segment's text run.
    /// - Returns: Block elements.
    public func textBlocks(messageID: String, text: String) -> [ChatTextBlock] {
        let key = "\(messageID)-\(text.hashValue)"
        if let cached = blocks[key] { return cached }
        let result = ChatTextBlockParser().blocks(from: text)
        if blocks.count >= capacity, let oldest = blockOrder.first {
            blocks[oldest] = nil
            blockOrder.removeFirst()
        }
        blocks[key] = result
        blockOrder.append(key)
        return result
    }

    public func proseSegments(messageID: String, text: String) -> [ChatProseSegment] {
        let key = "\(messageID)-\(text.hashValue)"
        if let cached = segments[key] { return cached }
        let result = ChatProseSegmenter().segments(from: text)
        if segments.count >= capacity, let oldest = segmentOrder.first {
            segments[oldest] = nil
            segmentOrder.removeFirst()
        }
        segments[key] = result
        segmentOrder.append(key)
        return result
    }
}

extension EnvironmentValues {
    /// The shared row-content cache, injected by the conversation screen.
    /// Rows fall back to uncached computation when absent (previews).
    @Entry public var chatContentCache: ChatContentCache? = nil
}
