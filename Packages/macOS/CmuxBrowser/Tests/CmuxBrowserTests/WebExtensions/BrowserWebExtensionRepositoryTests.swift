import CryptoKit
import Foundation
import Testing
@testable import CmuxBrowser

@Suite("Browser WebExtension repository")
struct BrowserWebExtensionRepositoryTests {
    @Test func arbitraryCompressedImportsAreRejected() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("untrusted.zip")
        try Data("not-even-a-zip".utf8).write(to: archive)
        let repository = BrowserWebExtensionDirectoryRepository()

        await #expect(throws: BrowserWebExtensionInstallError.compressedPackagesNotAllowed) {
            _ = try await repository.resolveInstallSource(at: archive)
        }
    }

    @Test func renamedArchiveRegularFileIsRejectedBeforePackageResolution() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let disguisedArchive = root.appendingPathComponent("disguised-extension.data")
        try makeStoredArchive().write(to: disguisedArchive)
        let repository = BrowserWebExtensionDirectoryRepository()

        await #expect(
            throws: BrowserWebExtensionInstallError.invalidPackage("disguised-extension.data")
        ) {
            _ = try await repository.resolveInstallSource(at: disguisedArchive)
        }
    }

    @Test func exactDigestCatalogArchiveIsAcceptedAndMismatchFailsClosed() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("verified.xpi")
        let bytes = makeStoredArchive()
        try bytes.write(to: archive)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let repository = BrowserWebExtensionDirectoryRepository()

        let source = try await repository.resolveInstallSource(
            at: archive,
            archivePolicy: .verifiedCatalog(expectedSHA256: digest)
        )
        guard case .managedPackage(let packageURL, _) = source else {
            Issue.record("Expected a managed catalog package")
            return
        }
        #expect(packageURL == archive)

        await #expect(throws: BrowserWebExtensionInstallError.integrityMismatch) {
            _ = try await repository.resolveInstallSource(
                at: archive,
                archivePolicy: .verifiedCatalog(expectedSHA256: String(repeating: "0", count: 64))
            )
        }
    }

    @Test func catalogArchivePreflightRejectsTraversalSymlinksAndExpandedBombs() throws {
        let preflight = BrowserWebExtensionArchivePreflight()
        let traversal = makeStoredArchive(path: "../manifest.json")
        let symlink = makeStoredArchive(externalAttributes: UInt32(0o120777) << 16)
        let expandedBomb = makeStoredArchive(declaredExpandedSize: 1024)
        let tightLimits = BrowserWebExtensionArchiveLimits(
            maximumCompressedByteCount: 1024 * 1024,
            maximumExpandedByteCount: 128,
            maximumEntryCount: 10
        )

        #expect(throws: BrowserWebExtensionInstallError.invalidPackage("traversal.xpi")) {
            try preflight.validate(traversal, packageName: "traversal.xpi", limits: .standard)
        }
        #expect(throws: BrowserWebExtensionInstallError.symbolicLinksNotAllowed) {
            try preflight.validate(symlink, packageName: "symlink.xpi", limits: .standard)
        }
        #expect(throws: BrowserWebExtensionInstallError.packageTooLarge) {
            try preflight.validate(expandedBomb, packageName: "bomb.xpi", limits: tightLimits)
        }
    }

    @Test func catalogArchivePreflightRejectsDuplicateEntryNames() throws {
        let archive = makeStoredArchive(entries: [
            ("manifest.json", Data("{}".utf8), 0, nil),
            ("manifest.json", Data("{\"name\":\"replacement\"}".utf8), 0, nil),
        ])

        #expect(throws: BrowserWebExtensionInstallError.invalidPackage("duplicate.xpi")) {
            try BrowserWebExtensionArchivePreflight().validate(
                archive,
                packageName: "duplicate.xpi",
                limits: .standard
            )
        }
    }

    @Test func safariAppPreflightRejectsOversizedAndSymlinkedInfoPlists() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = BrowserWebExtensionDirectoryRepository()
        let oversized = try makeSafariAppExtension(named: "Oversized.appex", in: root)
        try Data(repeating: 0, count: 1024 * 1024 + 1).write(
            to: oversized.appendingPathComponent("Contents/Info.plist")
        )
        await #expect(throws: BrowserWebExtensionInstallError.packageTooLarge) {
            _ = try await repository.resolveInstallSource(at: oversized)
        }

        let symlinked = try makeSafariAppExtension(named: "Symlinked.appex", in: root)
        let infoURL = symlinked.appendingPathComponent("Contents/Info.plist")
        try FileManager.default.removeItem(at: infoURL)
        try FileManager.default.createSymbolicLink(
            at: infoURL,
            withDestinationURL: oversized.appendingPathComponent("Contents/Info.plist")
        )
        await #expect(throws: BrowserWebExtensionInstallError.symbolicLinksNotAllowed) {
            _ = try await repository.resolveInstallSource(at: symlinked)
        }
    }

    @Test func managementLedgerRoundTripsAndDisabledRecordsDoNotLoad() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let extensionDirectory = root.appendingPathComponent("extension", isDirectory: true)
        try FileManager.default.createDirectory(at: extensionDirectory, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: extensionDirectory.appendingPathComponent("manifest.json"))
        let repository = BrowserWebExtensionDirectoryRepository()
        let digest = try await repository.digestForManagedPackage(at: extensionDirectory)
        let record = BrowserWebExtensionManagedRecord(
            id: "disk:test",
            displayName: "Test",
            version: "1",
            source: .directory(filename: "extension", digest: digest),
            isEnabled: false,
            grantedPermissions: ["storage"],
            grantedMatchPatterns: ["https://example.com/*"]
        )

        try await repository.upsertManagedRecord(record, in: root)

        let ledger = try await repository.managementLedger(in: root)
        #expect(ledger.records[record.id] == record)
        let discovery = try await repository.managedInstallations(in: root)
        #expect(discovery.installations.isEmpty)
        #expect(discovery.failures.isEmpty)
    }

    @Test func conditionalManagementMutationsRejectStaleRecords() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = BrowserWebExtensionDirectoryRepository()
        let original = BrowserWebExtensionManagedRecord(
            id: "disk:test",
            displayName: "Original",
            version: "1",
            source: .directory(filename: "extension", digest: "digest"),
            isEnabled: true,
            grantedPermissions: [],
            grantedMatchPatterns: []
        )
        var replacement = original
        replacement.displayName = "Replacement"
        var staleReplacement = original
        staleReplacement.displayName = "Stale"
        try await repository.upsertManagedRecord(original, in: root)

        #expect(try await repository.replaceManagedRecord(
            replacement,
            expectedPreviousRecord: original,
            in: root
        ))
        #expect(try await !repository.replaceManagedRecord(
            staleReplacement,
            expectedPreviousRecord: original,
            in: root
        ))
        #expect(try await !repository.removeManagedRecord(
            id: original.id,
            expectedPreviousRecord: original,
            in: root
        ))
        #expect(try await repository.removeManagedRecord(
            id: replacement.id,
            expectedPreviousRecord: replacement,
            in: root
        ))
        #expect(try await repository.managementLedger(in: root).records.isEmpty)
    }

    @Test func discoveryDefersManagedPackageIntegrityCheckUntilLoad() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let extensionDirectory = root.appendingPathComponent("extension", isDirectory: true)
        try FileManager.default.createDirectory(at: extensionDirectory, withIntermediateDirectories: true)
        let manifest = extensionDirectory.appendingPathComponent("manifest.json")
        try Data("before".utf8).write(to: manifest)
        let repository = BrowserWebExtensionDirectoryRepository()
        let digest = try await repository.digestForManagedPackage(at: extensionDirectory)
        let record = BrowserWebExtensionManagedRecord(
            id: "disk:test",
            displayName: "Test",
            version: "1",
            source: .directory(filename: "extension", digest: digest),
            isEnabled: true,
            grantedPermissions: [],
            grantedMatchPatterns: []
        )
        try await repository.upsertManagedRecord(record, in: root)
        try Data("after".utf8).write(to: manifest)

        let discovery = try await repository.managedInstallations(in: root)

        #expect(discovery.installations.count == 1)
        #expect(discovery.installations.first?.record.id == record.id)
        #expect(discovery.failures.isEmpty)
        let digestAfterTamper = try await repository.digestForManagedPackage(at: extensionDirectory)
        #expect(digestAfterTamper != digest)
    }

    @Test func managedPackageDigestFramesPathsAndContentsUnambiguously() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstTree = root.appendingPathComponent("first", isDirectory: true)
        let secondTree = root.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: firstTree, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondTree, withIntermediateDirectories: true)

        try Data([0x58, 0x00, 0x62, 0x00, 0x59]).write(
            to: firstTree.appendingPathComponent("a")
        )
        try Data([0x58]).write(to: secondTree.appendingPathComponent("a"))
        try Data([0x59]).write(to: secondTree.appendingPathComponent("b"))

        let repository = BrowserWebExtensionDirectoryRepository()
        let firstDigest = try await repository.digestForManagedPackage(at: firstTree)
        let secondDigest = try await repository.digestForManagedPackage(at: secondTree)

        #expect(firstDigest != secondDigest)
    }

    @Test func singleFileManagedPackageDigestRemainsRawSHA256() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("fixture.zip")
        let bytes = Data("verified catalog archive".utf8)
        try bytes.write(to: archive)
        let expectedDigest = SHA256.hash(data: bytes)
            .map { String(format: "%02x", $0) }
            .joined()
        let repository = BrowserWebExtensionDirectoryRepository()

        let digest = try await repository.digestForManagedPackage(at: archive)

        #expect(digest == expectedDigest)
    }

    @Test func catalogLogicalIdentifierSurvivesVersionChanges() {
        let first = BrowserWebExtensionCatalogEntry(
            id: "sample",
            version: "1",
            packageURL: URL(string: "https://example.com/one.zip")!,
            packageSHA256: String(repeating: "1", count: 64)
        )
        let second = BrowserWebExtensionCatalogEntry(
            id: "sample",
            version: "2",
            packageURL: URL(string: "https://example.com/two.zip")!,
            packageSHA256: String(repeating: "2", count: 64)
        )

        #expect(first.installedManagementID == second.installedManagementID)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-web-extension-repository-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeStoredArchive(
        path: String = "manifest.json",
        content: Data = Data("{}".utf8),
        externalAttributes: UInt32 = 0,
        declaredExpandedSize: UInt32? = nil
    ) -> Data {
        makeStoredArchive(entries: [(path, content, externalAttributes, declaredExpandedSize)])
    }

    private func makeStoredArchive(
        entries: [(path: String, content: Data, externalAttributes: UInt32, declaredExpandedSize: UInt32?)]
    ) -> Data {
        var local = Data()
        var central = Data()
        for entry in entries {
            let name = Data(entry.path.utf8)
            let expandedSize = entry.declaredExpandedSize ?? UInt32(entry.content.count)
            let localOffset = UInt32(local.count)
            local.appendLittleEndian(UInt32(0x0403_4b50))
            local.appendLittleEndian(UInt16(20))
            local.appendLittleEndian(UInt16(0))
            local.appendLittleEndian(UInt16(0))
            local.appendLittleEndian(UInt16(0))
            local.appendLittleEndian(UInt16(0))
            local.appendLittleEndian(UInt32(0))
            local.appendLittleEndian(UInt32(entry.content.count))
            local.appendLittleEndian(expandedSize)
            local.appendLittleEndian(UInt16(name.count))
            local.appendLittleEndian(UInt16(0))
            local.append(name)
            local.append(entry.content)

            central.appendLittleEndian(UInt32(0x0201_4b50))
            central.appendLittleEndian(UInt16((3 << 8) | 20))
            central.appendLittleEndian(UInt16(20))
            central.appendLittleEndian(UInt16(0))
            central.appendLittleEndian(UInt16(0))
            central.appendLittleEndian(UInt16(0))
            central.appendLittleEndian(UInt16(0))
            central.appendLittleEndian(UInt32(0))
            central.appendLittleEndian(UInt32(entry.content.count))
            central.appendLittleEndian(expandedSize)
            central.appendLittleEndian(UInt16(name.count))
            central.appendLittleEndian(UInt16(0))
            central.appendLittleEndian(UInt16(0))
            central.appendLittleEndian(UInt16(0))
            central.appendLittleEndian(UInt16(0))
            central.appendLittleEndian(entry.externalAttributes)
            central.appendLittleEndian(localOffset)
            central.append(name)
        }

        var result = local
        let centralOffset = UInt32(result.count)
        result.append(central)
        result.appendLittleEndian(UInt32(0x0605_4b50))
        result.appendLittleEndian(UInt16(0))
        result.appendLittleEndian(UInt16(0))
        result.appendLittleEndian(UInt16(entries.count))
        result.appendLittleEndian(UInt16(entries.count))
        result.appendLittleEndian(UInt32(central.count))
        result.appendLittleEndian(centralOffset)
        result.appendLittleEndian(UInt16(0))
        return result
    }

    private func makeSafariAppExtension(named name: String, in root: URL) throws -> URL {
        let appex = root.appendingPathComponent(name, isDirectory: true)
        let resources = appex.appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.example.fixture",
            "NSExtension": [
                "NSExtensionPointIdentifier": "com.apple.Safari.web-extension",
            ],
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .binary,
            options: 0
        )
        try data.write(to: appex.appendingPathComponent("Contents/Info.plist"))
        try Data("{}".utf8).write(to: resources.appendingPathComponent("manifest.json"))
        return appex
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
