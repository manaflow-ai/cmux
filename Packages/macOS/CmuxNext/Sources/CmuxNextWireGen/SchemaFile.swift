import CmuxNextWireDigest
import Foundation

/// One schema file's bytes and its decoded header.
struct SchemaFile<Header: Decodable> {
    let bytes: Data
    let header: Header

    init(_ url: URL) throws(WireGenError) {
        let path = url.path(percentEncoded: false)
        let bytes: Data
        do {
            // blocking-allow: host build tool, not the app; no app thread to block.
            bytes = try Data(contentsOf: url)
        } catch {
            throw WireGenError.unreadable(path: path, reason: "\(error)")
        }
        do {
            header = try JSONDecoder().decode(Header.self, from: bytes)
        } catch {
            throw WireGenError.malformed(path: path, reason: "\(error)")
        }
        self.bytes = bytes
    }

    /// The file's ``WireDigest``, the value `WireSchemaIdentity.digest(of:)` recomputes.
    var digest: UInt64 {
        WireDigest(bytes).value
    }
}
