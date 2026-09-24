// Portions of this file are adapted from Search, a WebKit browser by Office
// Commun, https://github.com/driceroland/Search, MIT licensed.
// See THIRD_PARTY_LICENSES.md for the complete notice.

import CryptoKit
import Foundation
import Security

/// The authenticated part of installing a Chrome Web Store extension.
///
/// CRX3 files are signed archives. We verify the extension id, the public-key
/// hash that defines that id, and the signature over the exact ZIP bytes before
/// touching the filesystem. The archive extractor is deliberately separate so
/// callers cannot accidentally persist an unverified download.
enum BrowserExtensionArchive {
    enum Error: LocalizedError, Equatable {
        case invalidID
        case downloadFailed(Int)
        case responseTooLarge
        case emptyResponse
        case invalidCRX
        case invalidSignature
        case invalidArchive
        case archiveTooLarge
        case unsafeArchivePath
        case unsafeArchiveEntry
        case missingManifest

        var errorDescription: String? {
            switch self {
            case .invalidID: return "That is not a Chrome extension ID or Web Store link."
            case .downloadFailed(let status): return "The Chrome Web Store returned HTTP \(status)."
            case .responseTooLarge: return "The extension download is larger than cmux allows."
            case .emptyResponse: return "The Chrome Web Store returned an empty extension."
            case .invalidCRX: return "The downloaded file is not a CRX3 extension."
            case .invalidSignature: return "The extension signature does not match its Web Store ID."
            case .invalidArchive: return "The extension archive could not be read."
            case .archiveTooLarge: return "The extension expands beyond cmux's safety limit."
            case .unsafeArchivePath: return "The extension archive contains an unsafe path."
            case .unsafeArchiveEntry: return "The extension archive contains an unsafe filesystem entry."
            case .missingManifest: return "The extension has no manifest.json."
            }
        }
    }

    static let maximumDownloadBytes = 100 * 1024 * 1024
    static let maximumExpandedBytes = 512 * 1024 * 1024
    static let maximumEntryCount = 50_000
    private static let chromeVersion = "140.0.0.0"

    static func id(in text: String) -> String? {
        let pattern = try! NSRegularExpression(pattern: "(?<![a-z])([a-p]{32})(?![a-z])")
        let range = NSRange(text.startIndex..., in: text)
        guard let match = pattern.firstMatch(in: text.lowercased(), range: range),
              let found = Range(match.range(at: 1), in: text) else { return nil }
        return text[found].lowercased()
    }

    static func downloadURL(for id: String) -> URL {
        var parts = URLComponents(string: "https://clients2.google.com/service/update2/crx")!
        parts.queryItems = [
            URLQueryItem(name: "response", value: "redirect"),
            URLQueryItem(name: "prodversion", value: chromeVersion),
            URLQueryItem(name: "acceptformat", value: "crx3"),
            URLQueryItem(name: "x", value: "id=\(id)&installsource=ondemand&uc")
        ]
        return parts.url!
    }

    static func fetch(id: String, session: URLSession = .shared) async throws -> Data {
        guard id.range(of: "^[a-p]{32}$", options: .regularExpression) != nil else {
            throw Error.invalidID
        }
        var request = URLRequest(url: downloadURL(for: id))
        request.timeoutInterval = 60
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Error.invalidArchive }
        guard (200..<300).contains(http.statusCode) else { throw Error.downloadFailed(http.statusCode) }
        guard data.count <= maximumDownloadBytes else { throw Error.responseTooLarge }
        guard !data.isEmpty else { throw Error.emptyResponse }
        return data
    }

    static func verifiedZip(_ crx: Data, id: String) throws -> Data {
        guard id.range(of: "^[a-p]{32}$", options: .regularExpression) != nil else { throw Error.invalidID }
        let bytes = [UInt8](crx)
        guard bytes.count > 12, bytes[0..<4].elementsEqual(Array("Cr24".utf8)), le32(bytes, 4) == 3 else {
            throw Error.invalidCRX
        }
        let headerSize = Int(le32(bytes, 8))
        guard headerSize > 0, headerSize <= 4 * 1024 * 1024, 12 + headerSize <= bytes.count else {
            throw Error.invalidCRX
        }
        let header = Array(bytes[12..<(12 + headerSize)])
        let zip = Data(bytes[(12 + headerSize)...])
        guard zip.count >= 4, zip.prefix(4).elementsEqual([0x50, 0x4b, 0x03, 0x04]) else {
            throw Error.invalidCRX
        }

        let fields = try protobuf(header)
        guard let signedHeader = fields.first(where: { $0.field == 10000 })?.value else {
            throw Error.invalidSignature
        }
        let signedFields = try protobuf(signedHeader)
        guard let crxID = signedFields.first(where: { $0.field == 1 })?.value,
              letters(crxID) == id else { throw Error.invalidSignature }

        var message = Data("CRX3 SignedData".utf8)
        message.append(0)
        var length = UInt32(signedHeader.count).littleEndian
        message.append(Data(bytes: &length, count: 4))
        message.append(contentsOf: signedHeader)
        message.append(zip)

        // Chrome Web Store CRX3 packages currently contain an RSA proof whose
        // SPKI hash is the extension id. Ignore unrecognized proof fields and
        // require one valid proof over the exact ZIP bytes.
        let validProof = fields.filter { $0.field == 2 }.contains { proofField in
            guard let proof = try? protobuf(proofField.value),
                  let key = proof.first(where: { $0.field == 1 })?.value,
                  let signature = proof.first(where: { $0.field == 2 })?.value,
                  key.count >= 64, signature.count >= 64,
                  letters(Array(SHA256.hash(data: Data(key)).prefix(16))) == id else { return false }
            return verify(rsaSPKI: Data(key), signature: Data(signature), message: message)
        }
        guard validProof else { throw Error.invalidSignature }
        return zip
    }

    /// Extracts a verified ZIP into a new directory and rejects traversal,
    /// symlink, oversized, and malformed entries before it becomes loadable.
    static func unpack(_ zip: Data, into destination: URL, fileManager: FileManager = .default) throws {
        guard zip.count <= maximumDownloadBytes else { throw Error.responseTooLarge }
        let root = destination.standardizedFileURL
        let scratch = fileManager.temporaryDirectory.appendingPathComponent("cmux-extension-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratch) }
        let archive = scratch.appendingPathComponent("extension.zip")
        let output = scratch.appendingPathComponent("out", isDirectory: true)
        try zip.write(to: archive, options: [.atomic])
        try fileManager.createDirectory(at: output, withIntermediateDirectories: true)
        try validateArchiveEntries(archive, output: output)
        guard try run("/usr/bin/ditto", ["-x", "-k", archive.path, output.path]) == 0 else { throw Error.invalidArchive }
        try validateExtractedTree(output, destination: output)
        let manifest = output.appendingPathComponent("manifest.json")
        guard fileManager.fileExists(atPath: manifest.path), isRegularFile(manifest) else { throw Error.missingManifest }
        try? fileManager.removeItem(at: root)
        try fileManager.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.moveItem(at: output, to: root)
    }

    /// Copies a developer supplied unpacked extension with the same symlink and
    /// path checks used for Web Store archives.
    static func copyUnpacked(from source: URL, into destination: URL, fileManager: FileManager = .default) throws {
        let source = source.standardizedFileURL
        guard fileManager.fileExists(atPath: source.appendingPathComponent("manifest.json").path) else { throw Error.missingManifest }
        let root = destination.standardizedFileURL
        try validateExtractedTree(source, destination: source)
        try? fileManager.removeItem(at: root)
        try fileManager.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.copyItem(at: source, to: root)
        try validateExtractedTree(root, destination: root)
    }

    private struct Field { let field: Int; let value: [UInt8] }

    private static func protobuf(_ bytes: [UInt8]) throws -> [Field] {
        var fields: [Field] = []
        var index = 0
        func varint() throws -> Int {
            var value = 0
            var shift = 0
            while index < bytes.count {
                let byte = Int(bytes[index]); index += 1
                if shift >= 63 { throw Error.invalidCRX }
                value |= (byte & 0x7f) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
            }
            throw Error.invalidCRX
        }
        while index < bytes.count {
            let key = try varint()
            let field = key >> 3
            switch key & 7 {
            case 2:
                let length = try varint()
                guard length >= 0, length <= bytes.count - index else { throw Error.invalidCRX }
                fields.append(Field(field: field, value: Array(bytes[index..<(index + length)])))
                index += length
            case 0:
                _ = try varint()
            case 1:
                guard bytes.count - index >= 8 else { throw Error.invalidCRX }
                index += 8
            case 5:
                guard bytes.count - index >= 4 else { throw Error.invalidCRX }
                index += 4
            default:
                throw Error.invalidCRX
            }
        }
        return fields
    }

    private static func le32(_ bytes: [UInt8], _ index: Int) -> UInt32 {
        UInt32(bytes[index]) | UInt32(bytes[index + 1]) << 8 | UInt32(bytes[index + 2]) << 16 | UInt32(bytes[index + 3]) << 24
    }

    static func letters(_ bytes: [UInt8]) -> String {
        String(bytes.flatMap { [$0 >> 4, $0 & 0x0f] }.map { Character(UnicodeScalar(UInt8(97) + $0)) })
    }

    private static func verify(rsaSPKI: Data, signature: Data, message: Data) -> Bool {
        var format = SecExternalFormat.formatOpenSSL
        var type = SecExternalItemType.itemTypePublicKey
        var items: CFArray?
        guard SecItemImport(rsaSPKI as CFData, nil, &format, &type, [], nil, nil, &items) == errSecSuccess,
              let first = (items as? [Any])?.first else { return false }
        let key = first as! SecKey
        return SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, message as CFData, signature as CFData, nil)
    }

    private static func validateArchiveEntries(_ archive: URL, output: URL) throws {
        let listing = try outputOf("/usr/bin/unzip", ["-Z1", archive.path])
        let names = listing.split(whereSeparator: \.isNewline).map(String.init)
        guard names.count <= maximumEntryCount else { throw Error.archiveTooLarge }
        guard !names.isEmpty else { throw Error.invalidArchive }
        for name in names { try validateRelativePath(name) }
    }

    private static func validateExtractedTree(_ root: URL, destination: URL) throws {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) else { throw Error.invalidArchive }
        let rootPath = destination.standardizedFileURL.path.hasSuffix("/") ? destination.standardizedFileURL.path : destination.standardizedFileURL.path + "/"
        var total = 0
        var count = 0
        while let url = enumerator.nextObject() as? URL {
            count += 1
            guard count <= maximumEntryCount else { throw Error.archiveTooLarge }
            let standardized = url.standardizedFileURL.path
            guard standardized == destination.standardizedFileURL.path || standardized.hasPrefix(rootPath) else { throw Error.unsafeArchivePath }
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isSymbolicLink != true else { throw Error.unsafeArchiveEntry }
            if values.isRegularFile == true { total += values.fileSize ?? 0 }
            guard total <= maximumExpandedBytes else { throw Error.archiveTooLarge }
        }
    }

    private static func validateRelativePath(_ raw: String) throws {
        guard !raw.isEmpty, !raw.contains("\\"), !raw.contains("\0") else { throw Error.unsafeArchivePath }
        let path = raw.hasSuffix("/") ? String(raw.dropLast()) : raw
        guard !path.hasPrefix("/"), !path.split(separator: "/", omittingEmptySubsequences: false).contains("..") else { throw Error.unsafeArchivePath }
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    @discardableResult
    private static func run(_ executable: String, _ arguments: [String]) throws -> Int32 {
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit(); return process.terminationStatus
    }

    private static func outputOf(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process(); let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Error.invalidArchive }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}
