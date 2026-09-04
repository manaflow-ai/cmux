import Foundation

/// One durable artifact row shared by workspace and global views.
public struct ArtifactRecord: Codable, Equatable, Hashable, Sendable, Identifiable {
    /// Stable identity retained across restarts and deduplication updates.
    public let id: UUID
    /// Payload classification used for opening, search, and drag behavior.
    public let kind: ArtifactKind
    /// Canonical identity used to merge repeated observations.
    public let identityKey: String
    /// Workspace/project ownership metadata.
    public let ownership: ArtifactOwnership
    /// Capture provenance.
    public let source: ArtifactSource
    /// First observation timestamp.
    public let createdAt: Date
    /// Most recent observation timestamp.
    public let lastSeenAt: Date
    /// Number of observations folded into this row.
    public let occurrenceCount: Int
    /// Optional display title.
    public let title: String?
    /// Bounded searchable metadata (source surface, MIME type, and similar).
    public let metadata: [String: String]
    /// Safe open/drag representation.
    public let representation: ArtifactRepresentation
    /// Whether the user explicitly selected or supplied this payload.
    /// User-owned payloads are never silently evicted by automatic retention.
    public let isUserOwned: Bool

    /// Creates a durable artifact record.
    public init(
        id: UUID = UUID(),
        kind: ArtifactKind,
        identityKey: String,
        ownership: ArtifactOwnership,
        source: ArtifactSource,
        createdAt: Date = .now,
        lastSeenAt: Date = .now,
        occurrenceCount: Int = 1,
        title: String? = nil,
        metadata: [String: String] = [:],
        representation: ArtifactRepresentation,
        isUserOwned: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.identityKey = identityKey
        self.ownership = ownership
        self.source = source
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
        self.occurrenceCount = max(1, occurrenceCount)
        self.title = Self.boundedString(title, maximumBytes: 2_048)
        self.metadata = Self.boundedMetadata(metadata)
        self.representation = representation
        self.isUserOwned = isUserOwned
    }

    /// Returns inline content when this record can be searched without I/O.
    public var inlineContent: String? {
        switch representation {
        case .inlineText(let value), .inlineHTML(let value): value
        default: nil
        }
    }

    /// Returns the strongest safe textual copy value for this record.
    public var copyValue: String {
        switch representation {
        case .url(let value), .directory(let value): value
        case .managedFile(_, let suggestedFileName): suggestedFileName
        case .inlineText(let value), .inlineHTML(let value): value
        }
    }

    /// Normalized host metadata used by the legacy Links host filter.
    public var hostKey: String? {
        if let host = metadata["host"]?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty {
            return host.lowercased()
        }
        guard case .url(let value) = representation else { return nil }
        return URL(string: value)?.host?.lowercased()
    }

    /// Whether this record is a URL-shaped row, including legacy `file://`
    /// entries represented as `.file` for compatibility.
    public var isURLLike: Bool {
        if kind == .url { return true }
        guard kind == .file else { return false }
        if case .url = representation { return true }
        return false
    }

    /// Returns the fields searched by ``ArtifactSearchEngine`` and their weights.
    var searchableFields: [(String, Int)] {
        var fields: [(String, Int)] = []
        if let title, !title.isEmpty { fields.append((title, 1_000)) }
        fields.append((identityKey, 700))
        fields.append((copyValue, 900))
        if let hostKey { fields.append((hostKey, 650)) }
        fields.append((kind.rawValue, 450))
        fields.append((source.rawValue, 450))
        fields.append(contentsOf: metadata.map { ($0.key + " " + $0.value, 500) })
        if let inlineContent { fields.append((inlineContent, 300)) }
        if let workspaceTitle = ownership.workspaceTitle { fields.append((workspaceTitle, 200)) }
        if let projectRoot = ownership.projectRoot { fields.append((projectRoot, 200)) }
        return fields
    }

    /// Returns a record with observation fields merged from a subsequent capture.
    public func merging(
        source: ArtifactSource,
        lastSeenAt: Date,
        title: String?,
        metadata: [String: String],
        occurrenceIncrement: Int = 1
    ) -> ArtifactRecord {
        ArtifactRecord(
            id: id,
            kind: kind,
            identityKey: identityKey,
            ownership: ownership,
            source: source,
            createdAt: createdAt,
            lastSeenAt: max(self.lastSeenAt, lastSeenAt),
            occurrenceCount: occurrenceCount + max(1, occurrenceIncrement),
            title: title ?? self.title,
            metadata: self.metadata.merging(Self.boundedMetadata(metadata)) { current, _ in current },
            representation: representation,
            isUserOwned: isUserOwned
        )
    }

    /// Returns a copy with a newly fetched title.
    public func withTitle(_ title: String?) -> ArtifactRecord {
        ArtifactRecord(
            id: id,
            kind: kind,
            identityKey: identityKey,
            ownership: ownership,
            source: source,
            createdAt: createdAt,
            lastSeenAt: lastSeenAt,
            occurrenceCount: occurrenceCount,
            title: title,
            metadata: metadata,
            representation: representation,
            isUserOwned: isUserOwned
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, identityKey = "identity_key", ownership, source
        case createdAt = "created_at", lastSeenAt = "last_seen_at"
        case occurrenceCount = "occurrence_count", title, metadata, representation
        case isUserOwned = "is_user_owned"
    }

    /// Decodes both the current document and early prototype rows.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try container.decodeIfPresent(ArtifactKind.self, forKey: .kind) ?? .file
        ownership = try container.decodeIfPresent(ArtifactOwnership.self, forKey: .ownership) ?? ArtifactOwnership()
        source = try container.decodeIfPresent(ArtifactSource.self, forKey: .source) ?? .manual
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        lastSeenAt = try container.decodeIfPresent(Date.self, forKey: .lastSeenAt) ?? createdAt
        occurrenceCount = max(1, try container.decodeIfPresent(Int.self, forKey: .occurrenceCount) ?? 1)
        title = Self.boundedString(try container.decodeIfPresent(String.self, forKey: .title), maximumBytes: 2_048)
        metadata = Self.boundedMetadata(try container.decodeIfPresent([String: String].self, forKey: .metadata) ?? [:])
        isUserOwned = try container.decodeIfPresent(Bool.self, forKey: .isUserOwned) ?? false
        let decodedRepresentation: ArtifactRepresentation?
        if let representation = try container.decodeIfPresent(ArtifactRepresentation.self, forKey: .representation) {
            decodedRepresentation = representation
        } else if let legacyURL = try container.decodeIfPresent(String.self, forKey: .identityKey) {
            decodedRepresentation = .url(legacyURL)
        } else {
            decodedRepresentation = .inlineText("")
        }
        self.representation = decodedRepresentation ?? .inlineText("")
        let decodedKind = kind
        let decodedID = id
        let fallbackIdentity: String = {
            switch decodedRepresentation {
            case .some(.url(let value)): return ArtifactIdentity().key(kind: .url, value: value)
            case .some(.directory(let value)): return ArtifactIdentity().key(kind: .directory, value: value)
            case .some(.managedFile(let path, _)): return ArtifactIdentity().key(kind: .file, value: path)
            case .some(.inlineText(let value)), .some(.inlineHTML(let value)): return ArtifactIdentity().key(kind: decodedKind, value: value)
            case .none: return "\(decodedKind.rawValue):\(decodedID.uuidString)"
            }
        }()
        let decodedIdentity = try container.decodeIfPresent(String.self, forKey: .identityKey) ?? fallbackIdentity
        self.identityKey = decodedIdentity
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(identityKey, forKey: .identityKey)
        try container.encode(ownership, forKey: .ownership)
        try container.encode(source, forKey: .source)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(lastSeenAt, forKey: .lastSeenAt)
        try container.encode(occurrenceCount, forKey: .occurrenceCount)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encode(metadata, forKey: .metadata)
        try container.encode(representation, forKey: .representation)
        try container.encode(isUserOwned, forKey: .isUserOwned)
    }

    private static func boundedString(_ value: String?, maximumBytes: Int) -> String? {
        guard let value else { return nil }
        let bytes = Array(value.utf8.prefix(maximumBytes))
        let bounded = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return bounded.isEmpty ? nil : bounded
    }

    private static func boundedMetadata(_ values: [String: String]) -> [String: String] {
        values
            .sorted { $0.key < $1.key }
            .prefix(32)
            .reduce(into: [:]) { result, item in
                guard let key = boundedString(item.key, maximumBytes: 128),
                      let value = boundedString(item.value, maximumBytes: 1_024) else { return }
                result[key] = value
            }
    }
}
