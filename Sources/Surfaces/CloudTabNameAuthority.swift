import Foundation

/// The daemon persists provenance separately from display text. Legacy named
/// tabs are user-owned; a daemon without revision metadata cannot admit auto names.
/// The extension map keeps snapshots compatible with released strict SDK decoders.
struct CloudTabNameAuthority: Hashable, Codable, Sendable {
    let source: CloudTabNameSource
    let revision: UInt64

    init?(snapshot: [String: Any]) {
        guard let metadata = snapshot["extra"] as? [String: Any],
              let raw = metadata["name_source"] as? String,
              let source = CloudTabNameSource(rawValue: raw),
              let revision = CloudWireNumber.unsigned(metadata["name_revision"]) else { return nil }
        self.source = source
        self.revision = revision
    }
}
