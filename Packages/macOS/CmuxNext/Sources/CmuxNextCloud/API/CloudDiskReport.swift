import Foundation

/// The guest's root disk as a machine record carries it (cmux-cloud-machine `Machine.disk`, read from
/// the record's `disk_health`, cmux-cloud-disk `DiskReport`): used and free, and the used split into
/// system, project and caches (RFD 0068). Every field optional: no sample yet reports none, an older
/// guest no split.
public struct CloudDiskReport: Sendable, Hashable, Codable {
    public var totalBytes: UInt64?
    public var usedBytes: UInt64?
    public var freeBytes: UInt64?
    public var systemBytes: UInt64?
    public var projectBytes: UInt64?
    public var cachesBytes: UInt64?

    enum CodingKeys: String, CodingKey {
        case totalBytes = "total_bytes", usedBytes = "used_bytes", freeBytes = "free_bytes"
        case systemBytes = "system_bytes", projectBytes = "project_bytes", cachesBytes = "caches_bytes"
    }

    /// The report as the Cloud rules' list and status facts take it (cmux-cloud-handlers `Listed.disk`,
    /// `Status.disk`): the crate's own names, the fields it has.
    public var facts: [String: Any] {
        let fields: [(String, UInt64?)] = [
            ("total_bytes", totalBytes), ("used_bytes", usedBytes), ("free_bytes", freeBytes),
            ("system_bytes", systemBytes), ("project_bytes", projectBytes), ("caches_bytes", cachesBytes),
        ]
        return Dictionary(uniqueKeysWithValues: fields.compactMap { key, value in value.map { (key, $0) } })
    }
}
