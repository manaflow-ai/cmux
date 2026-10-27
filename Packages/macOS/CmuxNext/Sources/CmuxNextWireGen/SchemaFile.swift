import CmuxNextWireDigest
import Foundation

/// One schema file's bytes, read once for every emitter of a run.
struct SchemaInput {
    let path: String
    let bytes: Data

    init(_ url: URL) throws(WireGenError) {
        path = url.path(percentEncoded: false)
        do {
            // blocking-allow: host build tool, not the app; no app thread to block.
            bytes = try Data(contentsOf: url)
        } catch {
            throw WireGenError.unreadable(path: path, reason: "\(error)")
        }
    }
}

/// One schema file's bytes and its decoded header.
struct SchemaFile<Header: Decodable> {
    let bytes: Data
    let header: Header

    /// Decodes the header of bytes already read. Only the identity reads a header, so a run that
    /// writes no identity (the method-table fixture has no `protocol`) never decodes one.
    init(_ input: SchemaInput) throws(WireGenError) {
        do {
            header = try JSONDecoder().decode(Header.self, from: input.bytes)
        } catch {
            throw WireGenError.malformed(path: input.path, reason: "\(error)")
        }
        bytes = input.bytes
    }

    /// The file's ``WireDigest``, the value `WireSchemaIdentity.digest(of:)` recomputes.
    var digest: UInt64 {
        WireDigest(bytes).value
    }
}
