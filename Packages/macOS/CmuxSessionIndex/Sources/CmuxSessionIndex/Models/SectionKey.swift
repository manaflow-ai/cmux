public import Foundation

/// Identifier for a section in the index. For agent grouping, raw value is `agent:<rawValue>`;
/// for directory grouping, `dir:<absolute path>` (or `dir:` for unknown).
public struct SectionKey: Hashable, Sendable {
    public let raw: String

    public init(raw: String) {
        self.raw = raw
    }

    public static func agent(_ a: SessionAgent) -> SectionKey { SectionKey(raw: "agent:" + a.rawValue) }
    public static func directory(_ path: String?) -> SectionKey { SectionKey(raw: "dir:" + (path ?? "")) }

    public var isDirectory: Bool { raw.hasPrefix("dir:") }
}
