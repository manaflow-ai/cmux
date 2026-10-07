public import Foundation

/// `schemas/terminal-corpus/manifest.json`.
public struct TerminalCorpusManifest: Decodable, Hashable, Sendable {
    public struct Case: Decodable, Hashable, Sendable {
        public var name: String
        public var file: String
        public var cols: Int
        public var rows: Int
        public var bytes: Int
        public var features: [String]
    }

    public var version: Int
    public var cases: [Case]

    public init(decoding data: Data) throws {
        self = try JSONDecoder().decode(Self.self, from: data)
    }

    public func `case`(named name: String) -> Case? { cases.first { $0.name == name } }
}
