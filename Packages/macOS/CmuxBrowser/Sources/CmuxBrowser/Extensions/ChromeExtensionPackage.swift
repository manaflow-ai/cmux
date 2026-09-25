// Portions adapted from Search (https://github.com/driceroland/Search,
// Sources/Search/Crx.swift at 491f3214063212fac176a7ad95467f0821040451),
// Copyright (c) 2026 Office Commun, MIT License. See THIRD_PARTY_LICENSES.md.

public import Foundation
import CryptoKit
import Security

/// Downloads, verifies, and unpacks Chrome Web Store extensions (CRX3).
///
/// A Chrome extension id is the first 16 bytes of the SHA-256 of the
/// publisher's public key, written with the letters `a`-`p`. Verification
/// therefore requires a proof whose key hashes to the requested id and whose
/// signature covers the signed header and the zip payload. A payload that was
/// altered in transit, or one signed by any other key, is refused before
/// anything touches disk.
public enum ChromeExtensionPackage {
    public enum Failure: Error, Equatable, Sendable {
        case notAnExtensionID
        case download(statusCode: Int)
        case empty
        case notCRX3
        case signatureInvalid
        case publisherSignatureMissing
        case tooLarge
        case unpack(String)
    }

    /// Chrome version reported to the Web Store update service. Extensions may
    /// declare `minimum_chrome_version`; the service refuses older browsers.
    public static let reportedChromeVersion = "140.0.0.0"

    /// SHA-256 of the Chrome Web Store publisher key (Chromium
    /// `components/crx_file/crx_verifier.cc`, `kPublisherKeyHash`).
    static let webStorePublisherKeyHash: [UInt8] = [
        0x61, 0xf7, 0xf2, 0xa6, 0xbf, 0xcf, 0x74, 0xcd, 0x0b, 0xc1, 0xfe, 0x24, 0x97, 0xcc, 0x9b, 0x04,
        0x25, 0x4c, 0x65, 0x8f, 0x79, 0xf2, 0x14, 0x53, 0x92, 0x86, 0x7e, 0xa8, 0x36, 0x63, 0x67, 0xcf,
    ]

    /// Upper bound on a downloaded CRX. The largest popular store extensions
    /// are tens of megabytes; this guards against unbounded memory use.
    public static let maximumPackageBytes = 256 * 1024 * 1024

    /// Limits applied while unpacking, so a small archive cannot expand into
    /// an unbounded tree.
    public static let maximumExpandedBytes = 512 * 1024 * 1024
    public static let maximumEntryCount = 50_000

    /// Limits on the signed CRX header, checked before its fields are copied.
    static let maximumHeaderBytes = 256 * 1024
    static let maximumHeaderFields = 64
    static let maximumProofBytes = 16 * 1024
    /// `unzip -Z1` prints one name per entry; this bounds the listing well
    /// above `maximumEntryCount` typical names.
    static let maximumListingBytes = 8 * 1024 * 1024
    static let maximumPathBytes = 1024
    static let maximumPathDepth = 32

    /// Returns the 32-letter extension id in a bare id, a
    /// `chromewebstore.google.com/detail/...` URL, or a legacy
    /// `chrome.google.com/webstore/detail/...` URL.
    public static func extensionID(in text: String) -> String? {
        let lowered = text.lowercased()
        guard let regex = try? NSRegularExpression(pattern: "(?<![a-z])([a-p]{32})(?![a-z])") else { return nil }
        let range = NSRange(lowered.startIndex..., in: lowered)
        guard let match = regex.firstMatch(in: lowered, range: range),
              let found = Range(match.range(at: 1), in: lowered)
        else { return nil }
        return String(lowered[found])
    }

    /// Whether `id` is a syntactically valid Chrome extension id.
    public static func isExtensionID(_ id: String) -> Bool {
        id.utf8.count == 32 && id.utf8.allSatisfy { $0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "p") }
    }

    /// The public Web Store update endpoint every Chromium browser uses.
    public static func downloadURL(forExtensionID id: String) -> URL? {
        guard isExtensionID(id) else { return nil }
        var components = URLComponents(string: "https://clients2.google.com/service/update2/crx")
        components?.queryItems = [
            URLQueryItem(name: "response", value: "redirect"),
            URLQueryItem(name: "prodversion", value: reportedChromeVersion),
            URLQueryItem(name: "acceptformat", value: "crx3"),
            URLQueryItem(name: "x", value: "id=\(id)&installsource=ondemand&uc"),
        ]
        return components?.url
    }

    /// Update-check endpoint for an installed extension at `version`.
    public static func updateCheckURL(forExtensionID id: String, version: String) -> URL? {
        guard isExtensionID(id) else { return nil }
        var components = URLComponents(string: "https://clients2.google.com/service/update2/crx")
        components?.queryItems = [
            URLQueryItem(name: "response", value: "updatecheck"),
            URLQueryItem(name: "prodversion", value: reportedChromeVersion),
            URLQueryItem(name: "acceptformat", value: "crx3"),
            URLQueryItem(name: "x", value: "id=\(id)&v=\(version)&uc"),
        ]
        return components?.url
    }

    /// Whether Chrome version `candidate` is strictly newer than `current`.
    /// Chrome versions are one to four dot-separated integers; anything else
    /// is never newer, so a malformed update cannot replace an installed one.
    public static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        func parts(_ text: String) -> [Int]? {
            let pieces = text.split(separator: ".", omittingEmptySubsequences: false)
            guard (1...4).contains(pieces.count) else { return nil }
            let numbers = pieces.compactMap { Int($0) }
            guard numbers.count == pieces.count, numbers.allSatisfy({ $0 >= 0 }) else { return nil }
            return numbers + Array(repeating: 0, count: 4 - numbers.count)
        }
        guard let new = parts(candidate), let old = parts(current) else { return false }
        return new.lexicographicallyPrecedes(old) == false && new != old
    }

    /// Reads the version offered by an update-check response, or `nil` when
    /// the response says there is no update. Only the `<updatecheck>` element
    /// is inspected: the XML declaration also carries a `version` attribute.
    public static func offeredVersion(inUpdateCheckResponse xml: String) -> String? {
        guard let elementRange = xml.range(of: #"<updatecheck\b[^>]*>"#, options: .regularExpression) else { return nil }
        let element = String(xml[elementRange])
        guard element.contains(#"status="ok""#),
              let versionRange = element.range(of: #"\bversion="([^"]+)""#, options: .regularExpression)
        else { return nil }
        return String(element[versionRange].dropFirst(#"version=""#.count).dropLast())
    }

    /// Downloads the CRX for `id`.
    public static func download(extensionID id: String, session: URLSession = .shared) async throws -> Data {
        guard let url = downloadURL(forExtensionID: id) else { throw Failure.notAnExtensionID }
        return try await boundedData(from: url, session: session, limit: maximumPackageBytes)
    }

    /// Fetches `url`, refusing responses over `limit` bytes as they stream in
    /// rather than after buffering them whole.
    public static func boundedData(from url: URL, session: URLSession = .shared, limit: Int) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        let (bytes, response) = try await session.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure.download(statusCode: http.statusCode)
        }
        if response.expectedContentLength > Int64(limit) { throw Failure.tooLarge }
        var data = Data()
        if response.expectedContentLength > 0 { data.reserveCapacity(Int(response.expectedContentLength)) }
        for try await byte in bytes {
            data.append(byte)
            if data.count > limit { throw Failure.tooLarge }
        }
        guard !data.isEmpty else { throw Failure.empty }
        return data
    }

    /// Returns the zip payload of `crx` after verifying its CRX3 signature
    /// against `id`.
    public static func verifiedZip(_ crx: Data, extensionID id: String) throws -> Data {
        guard isExtensionID(id) else { throw Failure.notAnExtensionID }
        // Only the small fixed prefix and the bounded header are copied into
        // arrays; the payload stays in `crx` until the signed message is built.
        guard crx.count > 12 else { throw Failure.notCRX3 }
        let prefix = [UInt8](crx.prefix(12))
        guard Array(prefix[0..<4]) == Array("Cr24".utf8) else { throw Failure.notCRX3 }
        guard littleEndianUInt32(prefix, at: 4) == 3 else { throw Failure.notCRX3 }
        let headerSize = Int(littleEndianUInt32(prefix, at: 8))
        guard headerSize > 0, headerSize <= maximumHeaderBytes, 12 + headerSize < crx.count else { throw Failure.notCRX3 }
        let start = crx.startIndex
        let header = [UInt8](crx[(start + 12)..<(start + 12 + headerSize)])
        let zip = crx[(start + 12 + headerSize)...]

        // CrxFileHeader fields: 2 = sha256_with_rsa proofs,
        // 3 = sha256_with_ecdsa proofs, 10000 = signed_header_data
        // (SignedData, whose field 1 is crx_id).
        let fields = lengthDelimitedFields(header)
        guard fields.count <= maximumHeaderFields,
              let signedHeader = fields.first(where: { $0.field == 10000 })?.bytes,
              let crxID = lengthDelimitedFields(signedHeader).first(where: { $0.field == 1 })?.bytes,
              crxID.count == 16,
              letters(crxID) == id
        else { throw Failure.signatureInvalid }

        // SHA-256 of the signed message, hashed in place: the message is the
        // prefix, the signed header, and the payload, and is never copied.
        var hasher = SHA256()
        hasher.update(data: Data("CRX3 SignedData".utf8))
        hasher.update(data: Data([0]))
        var length = UInt32(signedHeader.count).littleEndian
        withUnsafeBytes(of: &length) { hasher.update(bufferPointer: $0) }
        hasher.update(data: Data(signedHeader))
        hasher.update(data: zip)
        let digest = hasher.finalize()

        // The developer proof is the RSA proof whose key hashes to the id.
        // The Web Store adds its own proof too; it is not the one that binds
        // the payload to the requested id.
        let proofs = fields.filter { $0.field == 2 }.map { lengthDelimitedFields($0.bytes) }
        let developerSigned = proofs.contains { proof in
            guard let key = proof.first(where: { $0.field == 1 })?.bytes,
                  let signature = proof.first(where: { $0.field == 2 })?.bytes,
                  key.count <= maximumProofBytes, signature.count <= maximumProofBytes,
                  letters(Array(SHA256.hash(data: Data(key)).prefix(16))) == id
            else { return false }
            return verifyRSA(subjectPublicKeyInfo: Data(key), signature: Data(signature), digest: digest)
        }
        guard developerSigned else { throw Failure.signatureInvalid }

        // Chrome also requires the Web Store's publisher proof for store
        // installs: an ECDSA P-256 proof by the key whose SHA-256 is
        // `webStorePublisherKeyHash`. A leaked developer key alone is then
        // not enough to ship code under a store id.
        let ecdsaProofs = fields.filter { $0.field == 3 }.map { lengthDelimitedFields($0.bytes) }
        let publisherSigned = ecdsaProofs.contains { proof in
            guard let key = proof.first(where: { $0.field == 1 })?.bytes,
                  let signature = proof.first(where: { $0.field == 2 })?.bytes,
                  key.count <= maximumProofBytes, signature.count <= maximumProofBytes,
                  Array(SHA256.hash(data: Data(key))) == webStorePublisherKeyHash
            else { return false }
            return verifyP256(subjectPublicKeyInfo: Data(key), derSignature: Data(signature), digest: digest)
        }
        guard publisherSigned else { throw Failure.publisherSignatureMissing }
        // A slice shares the download's storage instead of copying the payload.
        return zip
    }

    /// Unpacks `zip` into `destination`, replacing it.
    ///
    /// Every entry name is checked before anything is written: absolute
    /// paths, `..` components, backslashes, and NUL bytes are refused, as are
    /// archives with too many entries. Extraction then happens in a private
    /// scratch directory, and the result is refused when it contains a
    /// symbolic link, a hard-linked or special file, a path that resolves
    /// outside the extraction root, more than ``maximumExpandedBytes``, or no
    /// `manifest.json`.
    public static func unpack(_ zip: Data, into destination: URL, fileManager: FileManager = .default) throws {
        guard zip.count <= maximumPackageBytes else { throw Failure.unpack("the extension is too large") }
        let scratch = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-crx-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratch) }
        let archive = scratch.appendingPathComponent("payload.zip")
        try zip.write(to: archive)
        let output = scratch.appendingPathComponent("out", isDirectory: true)

        let listing = try runCapturingOutput("/usr/bin/unzip", ["-Z1", archive.path], maximumBytes: maximumListingBytes)
        try validateArchiveEntryNames(listing.split(whereSeparator: \.isNewline).map(String.init))
        // Refuse archives whose central directory declares more than the
        // expansion budget before writing anything. The tree is measured again
        // after extraction, since a hostile archive can understate sizes.
        let totals = try runCapturingOutput("/usr/bin/unzip", ["-Zt", archive.path], maximumBytes: 4096)
        guard let declared = declaredUncompressedBytes(inZipInfoTotals: totals),
              declared <= Int64(maximumExpandedBytes) else {
            throw Failure.unpack("the extension is too large")
        }

        try runCapturingOutput(
            "/usr/bin/ditto",
            ["-x", "-k", "--norsrc", "--noextattr", "--noacl", archive.path, output.path]
        )
        try validateUnpackedTree(at: output, fileManager: fileManager)
        try replace(destination, with: output, fileManager: fileManager)
    }

    /// Copies a developer's unpacked extension folder into `destination` with
    /// the same tree checks used for store archives. The source is validated
    /// before and after the copy, so a symlink swapped in mid-copy is caught.
    public static func copyUnpacked(from source: URL, into destination: URL, fileManager: FileManager = .default) throws {
        try validateUnpackedTree(at: source, fileManager: fileManager)
        let scratch = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-unpacked-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: scratch) }
        try fileManager.copyItem(at: source, to: scratch)
        try validateUnpackedTree(at: scratch, fileManager: fileManager)
        try replace(destination, with: scratch, fileManager: fileManager)
    }

    /// Reads the uncompressed total from `zipinfo -t` output, for example
    /// `12 files, 34567 bytes uncompressed, 8901 bytes compressed:  74.2%`.
    public static func declaredUncompressedBytes(inZipInfoTotals text: String) -> Int64? {
        guard let range = text.range(of: #"([0-9]+) bytes uncompressed"#, options: .regularExpression) else { return nil }
        return Int64(text[range].split(separator: " ").first ?? "")
    }

    /// Refuses archive entry names that could escape the extraction root.
    public static func validateArchiveEntryNames(_ names: [String]) throws {
        guard !names.isEmpty else { throw Failure.unpack("the archive is empty") }
        guard names.count <= maximumEntryCount else { throw Failure.unpack("the archive has too many files") }
        // Directories the names imply count toward the entry budget too, and
        // path length and depth are bounded, before anything is written.
        var directories = Set<Substring>()
        for raw in names {
            guard raw.utf8.count <= maximumPathBytes else { throw Failure.unpack("an archive path is too long") }
            let parts = raw.split(separator: "/", omittingEmptySubsequences: true)
            guard parts.count <= maximumPathDepth else { throw Failure.unpack("an archive path is too deep") }
            for depth in 1..<max(parts.count, 1) {
                directories.insert(parts.prefix(depth).joined(separator: "/")[...])
            }
            guard names.count + directories.count <= maximumEntryCount else {
                throw Failure.unpack("the archive has too many files")
            }
        }
        for raw in names {
            guard !raw.isEmpty, !raw.contains("\\"), !raw.contains("\0") else {
                throw Failure.unpack("unsafe path in archive")
            }
            let path = raw.hasSuffix("/") ? String(raw.dropLast()) : raw
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !path.hasPrefix("/"), !components.contains("..") else {
                throw Failure.unpack("unsafe path in archive")
            }
        }
    }

    /// Refuses trees that could redirect writes or reads outside `root`.
    public static func validateUnpackedTree(at root: URL, fileManager: FileManager = .default) throws {
        let rootURL = root.resolvingSymlinksInPath().standardizedFileURL
        let rootPath = rootURL.path
        let manifest = rootURL.appendingPathComponent("manifest.json")
        let manifestValues = try? manifest.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard manifestValues?.isRegularFile == true, manifestValues?.isSymbolicLink != true else {
            throw Failure.unpack("manifest.json is missing")
        }
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .linkCountKey, .fileSizeKey]
        guard let enumerator = fileManager.enumerator(at: rootURL, includingPropertiesForKeys: keys) else {
            throw Failure.unpack("cannot enumerate extension files")
        }
        var entries = 0
        var expandedBytes = 0
        for case let item as URL in enumerator {
            entries += 1
            guard entries <= maximumEntryCount else { throw Failure.unpack("the extension has too many files") }
            let values = try item.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true { throw Failure.unpack("symbolic links are not allowed") }
            if values.isRegularFile == true {
                if (values.linkCount ?? 1) > 1 { throw Failure.unpack("hard links are not allowed") }
                expandedBytes += values.fileSize ?? 0
                guard expandedBytes <= maximumExpandedBytes else { throw Failure.unpack("the extension is too large") }
            } else if values.isDirectory != true {
                throw Failure.unpack("special files are not allowed")
            }
            let path = item.standardizedFileURL.path
            guard path.hasPrefix(rootPath + "/") else { throw Failure.unpack("path escapes the extension folder") }
        }
    }

    private static func replace(_ destination: URL, with source: URL, fileManager: FileManager) throws {
        try? fileManager.removeItem(at: destination)
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.moveItem(at: source, to: destination)
    }

    /// Runs a tool and returns its standard output. Output is drained before
    /// waiting for exit, so a listing larger than the pipe buffer cannot
    /// deadlock the child, and reading stops (and the child is terminated)
    /// once `maximumBytes` is exceeded.
    @discardableResult
    private static func runCapturingOutput(_ executable: String, _ arguments: [String], maximumBytes: Int = 1024 * 1024) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        var data = Data()
        let handle = pipe.fileHandleForReading
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            data.append(chunk)
            if data.count > maximumBytes {
                process.terminate()
                process.waitUntilExit()
                throw Failure.unpack("\(URL(fileURLWithPath: executable).lastPathComponent) output is too large")
            }
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure.unpack("\(URL(fileURLWithPath: executable).lastPathComponent) exited \(process.terminationStatus)")
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Encoding helpers

    /// Encodes bytes as a Chrome id: each nibble becomes a letter `a`...`p`.
    public static func letters(_ bytes: [UInt8]) -> String {
        String(bytes.flatMap { [$0 >> 4, $0 & 0x0f] }.map { Character(UnicodeScalar(UInt8(ascii: "a") + $0)) })
    }

    /// The Chrome id derived from a DER SubjectPublicKeyInfo, as used for
    /// unpacked extensions that declare `key` in their manifest.
    public static func extensionID(forPublicKey key: Data) -> String {
        letters(Array(SHA256.hash(data: key).prefix(16)))
    }

    private static func littleEndianUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }

    /// Parses the length-delimited fields of a protobuf message, skipping
    /// varint and fixed-width fields. A CRX header holds only the former.
    static func lengthDelimitedFields(_ bytes: [UInt8]) -> [(field: Int, bytes: [UInt8])] {
        var fields: [(field: Int, bytes: [UInt8])] = []
        var index = 0
        func readVarint() -> Int? {
            var value = 0
            var shift = 0
            while index < bytes.count {
                let byte = Int(bytes[index])
                index += 1
                value |= (byte & 0x7f) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
                if shift > 56 { return nil }
            }
            return nil
        }
        while index < bytes.count, fields.count <= maximumHeaderFields {
            guard let key = readVarint() else { break }
            switch key & 7 {
            case 2:
                // Compare against the remaining length so a huge declared
                // length cannot overflow `index + length`.
                guard let length = readVarint(), length >= 0, length <= bytes.count - index else { return fields }
                fields.append((key >> 3, Array(bytes[index..<(index + length)])))
                index += length
            case 0:
                _ = readVarint()
            case 1:
                guard bytes.count - index >= 8 else { return fields }
                index += 8
            case 5:
                guard bytes.count - index >= 4 else { return fields }
                index += 4
            default:
                return fields
            }
        }
        return fields
    }

    private static func verifyP256(subjectPublicKeyInfo: Data, derSignature: Data, digest: SHA256.Digest) -> Bool {
        guard let key = try? P256.Signing.PublicKey(derRepresentation: subjectPublicKeyInfo),
              let signature = try? P256.Signing.ECDSASignature(derRepresentation: derSignature)
        else { return false }
        return key.isValidSignature(signature, for: digest)
    }

    private static func verifyRSA(subjectPublicKeyInfo: Data, signature: Data, digest: SHA256.Digest) -> Bool {
        var format = SecExternalFormat.formatOpenSSL
        var itemType = SecExternalItemType.itemTypePublicKey
        var items: CFArray?
        guard SecItemImport(subjectPublicKeyInfo as CFData, nil, &format, &itemType, [], nil, nil, &items) == errSecSuccess,
              let imported = (items as? [AnyObject])?.first,
              CFGetTypeID(imported) == SecKeyGetTypeID()
        else { return false }
        // swiftlint:disable:next force_cast
        let key = imported as! SecKey
        return SecKeyVerifySignature(
            key,
            .rsaSignatureDigestPKCS1v15SHA256,
            Data(digest) as CFData,
            signature as CFData,
            nil
        )
    }
}
