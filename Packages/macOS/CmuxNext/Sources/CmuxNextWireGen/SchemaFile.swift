import Foundation

/// One schema file's bytes and its decoded header.
struct SchemaFile<Header: Decodable> {
    let bytes: Data
    let header: Header

    init(_ url: URL) throws(WireGenError) {
        let path = url.path(percentEncoded: false)
        let bytes: Data
        do {
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

    /// FNV-1a 64 of the file's bytes: the function of cmux-ipc's `fnv1a64` and
    /// `WireSchemaIdentity.digest(of:)` (this tool cannot import CmuxNextIPC, whose build runs it).
    var digest: UInt64 {
        bytes.reduce(UInt64(0xcbf2_9ce4_8422_2325)) { ($0 ^ UInt64($1)) &* 0x0000_0100_0000_01b3 }
    }
}
