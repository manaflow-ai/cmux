@_spi(CmuxHostTransport) import CmuxExtensionKit
import Foundation

/// Validated collection of sidebar extensions available to the host.
public struct CMUXSidebarExtensionRegistry: Sendable {
    private var recordsByID: [String: CMUXSidebarExtensionRecord]

    /// Creates a registry from extension records.
    /// - Parameter records: Records to validate and store by identifier.
    /// - Throws: `CMUXExtensionClientError.duplicateExtensionIdentifier` for duplicate ids, or manifest validation errors.
    public init(records: [CMUXSidebarExtensionRecord] = []) throws {
        var recordsByID: [String: CMUXSidebarExtensionRecord] = [:]
        for record in records {
            try validateSidebarManifest(record.manifest)
            if recordsByID[record.id] != nil {
                throw CMUXExtensionClientError.duplicateExtensionIdentifier(record.id)
            }
            recordsByID[record.id] = record
        }
        self.recordsByID = recordsByID
    }

    /// Records sorted by display name for deterministic presentation.
    public var records: [CMUXSidebarExtensionRecord] {
        recordsByID.values.sorted { $0.manifest.displayName < $1.manifest.displayName }
    }

    /// Looks up one extension record.
    /// - Parameter id: Manifest identifier to find.
    /// - Returns: Matching record.
    /// - Throws: `CMUXExtensionClientError.extensionNotFound` when no record exists.
    public func record(id: String) throws -> CMUXSidebarExtensionRecord {
        guard let record = recordsByID[id] else {
            throw CMUXExtensionClientError.extensionNotFound(id)
        }
        return record
    }
}
