import Foundation

/// The daemon persists provenance separately from display text. Legacy named
/// tabs are user-owned; a daemon without revision metadata cannot admit auto names.
struct CloudTabNameAuthority: Hashable, Codable, Sendable {
    let source: CloudTabNameSource
    let revision: UInt64

    init?(snapshot: [String: Any]) {
        guard let raw = snapshot["name_source"] as? String,
              let source = CloudTabNameSource(rawValue: raw),
              let revision = CloudWireNumber.unsigned(snapshot["name_revision"]) else { return nil }
        self.source = source
        self.revision = revision
    }
}
