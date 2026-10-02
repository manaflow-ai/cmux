import Foundation

/// A column pinned to a viewport edge (`sticky-columns-v1`).
public struct StickySnapshot: Sendable, Hashable, Decodable {
    public enum Edge: String, Sendable, Hashable, Decodable { case left, right }
    public enum Mode: String, Sendable, Hashable, Decodable { case docked, overlay }
    public var edge: Edge
    public var mode: Mode

    public init(edge: Edge, mode: Mode) {
        self.edge = edge
        self.mode = mode
    }

    enum CodingKeys: String, CodingKey { case edge, mode }

    /// Unknown values from a newer daemon fall back to the defaults
    /// (right, docked) rather than dropping the screen.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        edge = (try? c.decodeIfPresent(String.self, forKey: .edge)).flatMap { $0.flatMap(Edge.init(rawValue:)) } ?? .right
        mode = (try? c.decodeIfPresent(String.self, forKey: .mode)).flatMap { $0.flatMap(Mode.init(rawValue:)) } ?? .docked
    }
}
