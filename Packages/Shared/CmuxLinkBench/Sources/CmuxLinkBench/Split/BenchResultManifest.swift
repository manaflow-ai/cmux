import Foundation

/// The checked-in/bakeoff manifest format (`cmux-link-bench-manifest/1`).
/// Paths are relative to the manifest directory and are validated before
/// writing, so a copied comparison cannot silently reach another checkout.
public struct BenchResultManifest: Codable, Hashable, Sendable {
    public static let schema = "cmux-link-bench-manifest/1"

    public struct Entry: Codable, Hashable, Sendable {
        public let path: String
        public let group: String?
        public let role: String?
        public let run: Int?

        public init(path: String, group: String? = nil, role: String? = nil, run: Int? = nil) {
            self.path = path
            self.group = group
            self.role = role
            self.run = run
        }
    }

    public let schema: String
    public let name: String
    public let sourceCommit: String
    public let recordedAt: String
    public let description: String
    public let results: [Entry]

    public init(
        name: String,
        sourceCommit: String,
        recordedAt: String,
        description: String,
        results: [Entry]
    ) throws {
        guard !name.isEmpty, !sourceCommit.isEmpty, !recordedAt.isEmpty,
              !description.isEmpty, !results.isEmpty else {
            throw BenchSplitError.invalidDescriptor("manifest metadata")
        }
        for result in results {
            guard Self.isRelativePath(result.path) else {
                throw BenchSplitError.invalidDescriptor("manifest path \(result.path)")
            }
        }
        self.schema = Self.schema
        self.name = name
        self.sourceCommit = sourceCommit
        self.recordedAt = recordedAt
        self.description = description
        self.results = results
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public func write(to url: URL) throws {
        try encoded().write(to: url, options: .atomic)
    }

    public static func decode(_ data: Data) throws -> BenchResultManifest {
        let manifest = try JSONDecoder().decode(Self.self, from: data)
        guard manifest.schema == Self.schema, !manifest.results.isEmpty else {
            throw BenchSplitError.invalidDescriptor("manifest schema")
        }
        guard manifest.results.allSatisfy({ isRelativePath($0.path) }) else {
            throw BenchSplitError.invalidDescriptor("manifest path")
        }
        return manifest
    }

    private static func isRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !components.contains("..") && !components.contains("")
    }
}

public extension BenchResultManifest {
    /// Creates a one-result manifest beside a report. The result path is
    /// checked relative to `manifestURL` before any bytes are written.
    static func singleResult(
        name: String,
        sourceCommit: String,
        recordedAt: String,
        description: String,
        resultURL: URL,
        manifestURL: URL,
        group: String? = nil,
        role: String? = "split-session"
    ) throws -> BenchResultManifest {
        let base = manifestURL.deletingLastPathComponent().standardizedFileURL.path
        let result = resultURL.standardizedFileURL.path
        guard result != manifestURL.standardizedFileURL.path else {
            throw BenchSplitError.invalidDescriptor("result and manifest paths must differ")
        }
        guard result.hasPrefix(base + "/") else {
            throw BenchSplitError.invalidDescriptor("result is outside manifest directory")
        }
        let relative = String(result.dropFirst(base.count + 1))
        return try BenchResultManifest(
            name: name, sourceCommit: sourceCommit, recordedAt: recordedAt,
            description: description,
            results: [Entry(path: relative, group: group, role: role)]
        )
    }
}
