import Foundation

/// The daemon persists provenance separately from display text. Legacy named
/// tabs are user-owned; a daemon without revision metadata cannot admit auto names.
struct CloudTabNameAuthority: Hashable, Codable, Sendable {
    enum Source: String, Codable, Sendable { case user, auto }
    let source: Source
    let revision: UInt64

    init?(snapshot: [String: Any]) {
        guard let raw = snapshot["name_source"] as? String,
              let source = Source(rawValue: raw),
              let revision = CloudWireNumber.unsigned(snapshot["name_revision"]) else { return nil }
        self.source = source
        self.revision = revision
    }
}
