import CmuxNextIPC
import CmuxNextWireDigest
import Foundation
import Testing

/// `WireSchemaIdentity.built` exists only because CmuxNextWireGenPlugin ran CmuxNextWireGen in this
/// build; these tests hold it to the schema files in the tree, the way cmux-ipc's
/// `schema_identity_matches_the_schema_files_in_the_tree` holds the Rust side.
struct WireSchemaIdentityTests {
    /// cmux-tui/spec, found from this file (Packages/macOS/CmuxNext/Tests/CmuxNextIPCTests).
    static func spec(_ name: String) throws -> Data {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { root.deleteLastPathComponent() }
        return try Data(contentsOf: root.appending(path: "cmux-tui/spec/\(name)"))
    }

    static func object(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    static func keyCount(_ object: [String: Any], _ key: String) -> Int {
        (object[key] as? [String: Any])?.count ?? -1
    }

    @Test func builtIdentityMatchesTheSchemaFilesInTheTree() throws {
        let sdkBytes = try Self.spec("sdk-schema.json")
        let operationBytes = try Self.spec("resource-operations-v2.json")
        let sdk = try Self.object(sdkBytes)
        let operations = try Self.object(operationBytes)
        let sdkProtocol = try #require(sdk["protocol"] as? [String: Any])
        let built = WireSchemaIdentity.built

        #expect(built.sdkSchemaDigest == WireSchemaIdentity.digest(of: sdkBytes))
        #expect(built.resourceOperationsDigest == WireSchemaIdentity.digest(of: operationBytes))
        #expect(built.muxProtocol == sdkProtocol["name"] as? String)
        #expect(built.muxProtocolVersion == (sdkProtocol["version"] as? NSNumber)?.uint64Value)
        #expect(built.resourceProtocol == operations["protocol"] as? String)
        #expect(built.commandCount == Self.keyCount(sdk, "commands"))
        #expect(built.eventCount == Self.keyCount(sdk, "events"))
        #expect(built.resourceOperationCount == Self.keyCount(operations, "operations"))
        #expect(built.localOperationCount == Self.keyCount(operations, "local_operations"))
        #expect(built.commandCount > 0)
        #expect(built.resourceOperationCount > 0)
    }

    /// The published FNV-1a 64 vectors; cmux-ipc's `fnv1a64_matches_the_published_vectors` checks the same three.
    @Test func digestMatchesThePublishedVectors() {
        #expect(WireSchemaIdentity.digest(of: Data()) == 0xcbf2_9ce4_8422_2325)
        #expect(WireSchemaIdentity.digest(of: Data("a".utf8)) == 0xaf63_dc4c_8601_ec8c)
        #expect(WireSchemaIdentity.digest(of: Data("foobar".utf8)) == 0x8594_4171_f739_67e8)
    }

    /// Folding a file in pieces gives the digest of the whole, the value CmuxNextWireGen writes.
    @Test func digestOfPiecesIsTheDigestOfTheWhole() {
        var pieces = WireDigest()
        pieces.update(Data("foo".utf8))
        pieces.update(Data("bar".utf8))
        #expect(pieces == WireDigest(Data("foobar".utf8)))
        #expect(pieces.value == WireSchemaIdentity.digest(of: Data("foobar".utf8)))
        #expect(WireDigest().value == 0xcbf2_9ce4_8422_2325)
    }
}
