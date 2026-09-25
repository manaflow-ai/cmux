import CryptoKit
import Foundation
import Security
import Testing

@testable import CmuxBrowser

/// `Fixtures/json-formatter.crx` is JSON Formatter 0.10.2
/// (https://github.com/callumlocke/json-formatter, MIT), downloaded unchanged
/// from the Chrome Web Store update service. It carries a genuine developer
/// proof and a genuine Web Store publisher proof.
@Suite struct ChromeExtensionPackageTests {
    static let fixtureID = "bcjindcccaagfpapjjmafapmmgkkhgoa"

    static func fixture() throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "json-formatter", withExtension: "crx", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    @Test func verifiesGenuineStorePackage() throws {
        let zip = try ChromeExtensionPackage.verifiedZip(Self.fixture(), extensionID: Self.fixtureID)
        #expect(zip.prefix(4) == Data([0x50, 0x4b, 0x03, 0x04]))
    }

    @Test func rejectsPackageRequestedUnderAnotherID() throws {
        #expect(throws: ChromeExtensionPackage.Failure.signatureInvalid) {
            try ChromeExtensionPackage.verifiedZip(Self.fixture(), extensionID: String(repeating: "a", count: 32))
        }
    }

    @Test func rejectsTamperedPayload() throws {
        var crx = try Self.fixture()
        crx[crx.count - 40] ^= 0xff
        #expect(throws: ChromeExtensionPackage.Failure.signatureInvalid) {
            try ChromeExtensionPackage.verifiedZip(crx, extensionID: Self.fixtureID)
        }
    }

    @Test func rejectsNonCRXData() {
        #expect(throws: ChromeExtensionPackage.Failure.notCRX3) {
            try ChromeExtensionPackage.verifiedZip(Data("PK\u{3}\u{4}not a crx".utf8), extensionID: Self.fixtureID)
        }
    }

    /// A package correctly signed by its own developer key, but without the
    /// Web Store's publisher proof, is what a leaked developer key plus a
    /// network man-in-the-middle could produce. It must be refused.
    @Test func rejectsDeveloperSignedPackageWithoutPublisherProof() throws {
        let (crx, id) = try Self.selfSignedCRX(zip: Data([0x50, 0x4b, 0x03, 0x04, 1, 2, 3]))
        #expect(throws: ChromeExtensionPackage.Failure.publisherSignatureMissing) {
            try ChromeExtensionPackage.verifiedZip(crx, extensionID: id)
        }
    }

    /// A header whose field length is near `Int.max` must be refused, not
    /// crash on `index + length` overflow.
    @Test func refusesOverflowingProtobufLength() {
        var header: [UInt8] = [0x12] // field 2, length-delimited
        header += Self.varint(Int.max - 3)
        var crx = Data("Cr24".utf8)
        for value in [UInt32(3), UInt32(header.count)] {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { crx.append(contentsOf: $0) }
        }
        crx.append(contentsOf: header)
        crx.append(contentsOf: [0x50, 0x4b])
        #expect(throws: ChromeExtensionPackage.Failure.self) {
            try ChromeExtensionPackage.verifiedZip(crx, extensionID: Self.fixtureID)
        }
    }

    @Test func comparesChromeVersionsStrictly() {
        #expect(ChromeExtensionPackage.isVersion("2026.9.0", newerThan: "2026.8.0"))
        #expect(ChromeExtensionPackage.isVersion("1.10", newerThan: "1.9.9"))
        #expect(!ChromeExtensionPackage.isVersion("1.0", newerThan: "1.0.0"))
        #expect(!ChromeExtensionPackage.isVersion("0.9", newerThan: "1.0"))
        #expect(!ChromeExtensionPackage.isVersion("1.0.0.0.1", newerThan: "1.0"))
        #expect(!ChromeExtensionPackage.isVersion("1.x", newerThan: "1.0"))
    }

    @Test func refusesOversizedHeaderBeforeParsing() {
        var crx = Data("Cr24".utf8)
        for value in [UInt32(3), UInt32(ChromeExtensionPackage.maximumHeaderBytes + 1)] {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { crx.append(contentsOf: $0) }
        }
        crx.append(Data(count: ChromeExtensionPackage.maximumHeaderBytes + 16))
        #expect(throws: ChromeExtensionPackage.Failure.notCRX3) {
            try ChromeExtensionPackage.verifiedZip(crx, extensionID: Self.fixtureID)
        }
    }

    @Test func unpacksVerifiedPayload() throws {
        let zip = try ChromeExtensionPackage.verifiedZip(Self.fixture(), extensionID: Self.fixtureID)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-crx-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: destination) }
        try ChromeExtensionPackage.unpack(zip, into: destination)
        let manifest = try JSONSerialization.jsonObject(
            with: Data(contentsOf: destination.appendingPathComponent("manifest.json"))
        ) as? [String: Any]
        #expect(manifest?["name"] as? String == "JSON Formatter")
    }

    @Test(arguments: ["../evil.js", "/etc/passwd", "a/../../b", "a\\b", "ok/\0bad"])
    func rejectsUnsafeArchiveEntryNames(_ name: String) {
        #expect(throws: ChromeExtensionPackage.Failure.self) {
            try ChromeExtensionPackage.validateArchiveEntryNames(["manifest.json", name])
        }
    }

    @Test func refusesDeepOrLongArchivePaths() {
        let deep = (0..<40).map { "d\($0)" }.joined(separator: "/") + "/f.js"
        #expect(throws: ChromeExtensionPackage.Failure.self) {
            try ChromeExtensionPackage.validateArchiveEntryNames(["manifest.json", deep])
        }
        let long = String(repeating: "a", count: 2000) + ".js"
        #expect(throws: ChromeExtensionPackage.Failure.self) {
            try ChromeExtensionPackage.validateArchiveEntryNames(["manifest.json", long])
        }
    }

    @Test func acceptsOrdinaryArchiveEntryNames() throws {
        try ChromeExtensionPackage.validateArchiveEntryNames(["manifest.json", "icons/", "icons/128.png", "a..b.js"])
    }

    @Test func refusesUnpackedFolderContainingSymlink() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-unpacked-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: root.appendingPathComponent("manifest.json"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("secrets"),
            withDestinationURL: URL(fileURLWithPath: NSHomeDirectory())
        )
        #expect(throws: ChromeExtensionPackage.Failure.self) {
            try ChromeExtensionPackage.copyUnpacked(from: root, into: root.appendingPathExtension("copy"))
        }
    }

    @Test func refusesSymlinkedUnpackedRoot() throws {
        let real = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-real-\(UUID().uuidString)", isDirectory: true)
        let link = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-link-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: real); try? FileManager.default.removeItem(at: link) }
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: real.appendingPathComponent("manifest.json"))
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        #expect(throws: ChromeExtensionPackage.Failure.self) {
            try ChromeExtensionPackage.copyUnpacked(from: link, into: real.appendingPathExtension("copy"))
        }
    }

    @Test func parsesExtensionIDsFromStoreLinks() {
        #expect(ChromeExtensionPackage.extensionID(in: "https://chromewebstore.google.com/detail/json-formatter/bcjindcccaagfpapjjmafapmmgkkhgoa?hl=en") == Self.fixtureID)
        #expect(ChromeExtensionPackage.extensionID(in: "BCJINDCCCAAGFPAPJJMAFAPMMGKKHGOA") == Self.fixtureID)
        #expect(ChromeExtensionPackage.extensionID(in: "https://example.com/zzbcjindcccaagfpapjjmafapmmgkkhgoa") == nil)
        #expect(ChromeExtensionPackage.extensionID(in: "not an id") == nil)
    }

    @Test func readsOfferedVersionFromUpdateCheckElementOnly() {
        let update = #"<?xml version="1.0" encoding="UTF-8"?><gupdate><app appid="x" status="ok"><updatecheck codebase="https://x" version="2.1.0" status="ok"/></app></gupdate>"#
        let none = #"<?xml version="1.0" encoding="UTF-8"?><gupdate><app appid="x" status="ok"><updatecheck status="noupdate"/></app></gupdate>"#
        #expect(ChromeExtensionPackage.offeredVersion(inUpdateCheckResponse: update) == "2.1.0")
        #expect(ChromeExtensionPackage.offeredVersion(inUpdateCheckResponse: none) == nil)
    }

    // MARK: - Helpers

    /// Builds a CRX3 whose only proof is an RSA proof by a fresh key, and
    /// returns it with the id that key defines.
    static func selfSignedCRX(zip: Data) throws -> (Data, String) {
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048]
        var error: Unmanaged<CFError>?
        let privateKey = try #require(SecKeyCreateRandomKey(attributes as CFDictionary, &error))
        let publicKey = try #require(SecKeyCopyPublicKey(privateKey))
        var exportedItem: CFData?
        let exportStatus = SecItemExport(publicKey, .formatOpenSSL, [], nil, &exportedItem)
        #expect(exportStatus == errSecSuccess)
        let spki = try #require(exportedItem as Data?)
        let id = ChromeExtensionPackage.extensionID(forPublicKey: spki)
        let idBytes = Array(SHA256.hash(data: spki).prefix(16))

        let signedHeader = field(1, idBytes)
        var message = Data("CRX3 SignedData".utf8)
        message.append(0)
        var length = UInt32(signedHeader.count).littleEndian
        withUnsafeBytes(of: &length) { message.append(contentsOf: $0) }
        message.append(contentsOf: signedHeader)
        message.append(zip)
        let signature = try #require(
            SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, message as CFData, &error) as Data?
        )

        let proof = field(1, Array(spki)) + field(2, Array(signature))
        let header = field(2, proof) + field(10000, signedHeader)
        var crx = Data("Cr24".utf8)
        for value in [UInt32(3), UInt32(header.count)] {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { crx.append(contentsOf: $0) }
        }
        crx.append(contentsOf: header)
        crx.append(zip)
        return (crx, id)
    }

    static func field(_ number: Int, _ bytes: [UInt8]) -> [UInt8] {
        varint((number << 3) | 2) + varint(bytes.count) + bytes
    }

    static func varint(_ value: Int) -> [UInt8] {
        var value = value
        var out: [UInt8] = []
        repeat {
            var byte = UInt8(value & 0x7f)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            out.append(byte)
        } while value != 0
        return out
    }
}
