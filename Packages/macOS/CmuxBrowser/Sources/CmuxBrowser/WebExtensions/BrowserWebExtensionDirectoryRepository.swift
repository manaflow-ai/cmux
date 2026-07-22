import CryptoKit
import Darwin
public import Foundation

public struct BrowserWebExtensionAppExtensionReference: Codable, Equatable, Sendable {
    public let bundleURL: URL
    public let bundleIdentifier: String
    public let installationName: String

    public init(bundleURL: URL, bundleIdentifier: String, installationName: String) {
        self.bundleURL = bundleURL
        self.bundleIdentifier = bundleIdentifier
        self.installationName = installationName
    }
}

public enum BrowserWebExtensionInstallSource: Sendable {
    case managedPackage(packageURL: URL, installationName: String)
    case appExtensionBundle(BrowserWebExtensionAppExtensionReference)
}

/// Moves extension-directory enumeration and metadata reads off the main actor.
public actor BrowserWebExtensionDirectoryRepository {
    public struct PackageLimits: Sendable {
        // Catalog downloads stay capped at 25 MB of compressed data. Installed
        // packages need a separate limit because production extensions such as
        // Bitwarden expand well beyond that while remaining bounded on disk.
        public static let standard = PackageLimits(
            maximumByteCount: 256 * 1024 * 1024,
            maximumFileCount: 10_000
        )

        public let maximumByteCount: Int
        public let maximumFileCount: Int

        public init(maximumByteCount: Int, maximumFileCount: Int) {
            precondition(maximumByteCount > 0)
            precondition(maximumFileCount > 0)
            self.maximumByteCount = maximumByteCount
            self.maximumFileCount = maximumFileCount
        }
    }

    private enum PackageEntryKind {
        case directory
        case regularFile
    }

    private struct PackageEntry {
        let sourceURL: URL
        let relativePath: String
        let kind: PackageEntryKind
    }

    private static let managementLedgerFileName = ".cmux-extension-management.json"
    private static let managedPackagePrefix = "cmux-extension-package-"
    private static let stagingPackagePrefix = ".cmux-extension-stage-"
    private static let copyChunkByteCount = 1024 * 1024
    private static let maximumLedgerByteCount = 1024 * 1024
    private static let maximumInfoPlistByteCount = 1024 * 1024
    private static let packageDigestDomain = Data("cmux.web-extension.package-digest".utf8)
    private static let packageDigestFormatVersion: UInt32 = 1
    private let packageLimits: PackageLimits
    private var isShutDown = false
#if DEBUG
    private var managedPackageDigestRequestCount = 0
#endif

    public init(packageLimits: PackageLimits = .standard) {
        self.packageLimits = packageLimits
    }

    public func shutdownAndRemoveDirectory(_ directory: URL) {
        isShutDown = true
        try? FileManager.default.removeItem(at: directory)
    }

    /// Reads the single versioned management ledger for a profile.
    public func managementLedger(in directory: URL) throws -> BrowserWebExtensionManagementLedger {
        try requireActive()
        let url = directory.appendingPathComponent(Self.managementLedgerFileName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return BrowserWebExtensionManagementLedger()
        }
        let ledger = try JSONDecoder().decode(
            BrowserWebExtensionManagementLedger.self,
            from: readBoundedLedgerData(at: url)
        )
        guard ledger.schemaVersion == BrowserWebExtensionManagementLedger.currentSchemaVersion else {
            throw BrowserWebExtensionInstallError.unsupportedManagementSchema
        }
        return ledger
    }

    /// Atomically persists one complete profile management ledger.
    public func writeManagementLedger(
        _ ledger: BrowserWebExtensionManagementLedger,
        in directory: URL
    ) throws {
        try requireActive()
        guard ledger.schemaVersion == BrowserWebExtensionManagementLedger.currentSchemaVersion else {
            throw BrowserWebExtensionInstallError.unsupportedManagementSchema
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ledgerURL = directory.appendingPathComponent(Self.managementLedgerFileName)
        if FileManager.default.fileExists(atPath: ledgerURL.path),
           try ledgerURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
            throw BrowserWebExtensionInstallError.symbolicLinksNotAllowed
        }
        try JSONEncoder().encode(ledger).write(
            to: ledgerURL,
            options: .atomic
        )
    }

    private func readBoundedLedgerData(at url: URL) throws -> Data {
        let handle = try openRegularFile(at: url)
        defer { try? handle.close() }
        var data = Data()
        while let chunk = try handle.read(upToCount: Self.copyChunkByteCount), !chunk.isEmpty {
            try requireActive()
            guard data.count <= Self.maximumLedgerByteCount - chunk.count else {
                throw BrowserWebExtensionInstallError.managementLedgerTooLarge
            }
            data.append(chunk)
        }
        return data
    }

    /// Inserts or replaces one durable record while preserving every other record.
    public func upsertManagedRecord(
        _ record: BrowserWebExtensionManagedRecord,
        in directory: URL
    ) throws {
        var ledger = try managementLedger(in: directory)
        ledger.records[record.id] = record
        try writeManagementLedger(ledger, in: directory)
    }

    /// Replaces one record only when it is still the value reviewed by the
    /// caller. The actor-isolated compare-and-swap closes the suspension race
    /// between permission decisions, updates, and management UI actions.
    @discardableResult
    public func replaceManagedRecord(
        _ record: BrowserWebExtensionManagedRecord,
        expectedPreviousRecord: BrowserWebExtensionManagedRecord?,
        in directory: URL
    ) throws -> Bool {
        var ledger = try managementLedger(in: directory)
        guard ledger.records[record.id] == expectedPreviousRecord else { return false }
        ledger.records[record.id] = record
        try writeManagementLedger(ledger, in: directory)
        return true
    }

    /// Removes one durable record and returns its previous value.
    @discardableResult
    public func removeManagedRecord(
        id: String,
        in directory: URL
    ) throws -> BrowserWebExtensionManagedRecord? {
        var ledger = try managementLedger(in: directory)
        let removed = ledger.records.removeValue(forKey: id)
        try writeManagementLedger(ledger, in: directory)
        return removed
    }

    /// Removes one record only when it is still the value the caller acted on.
    /// This prevents a delayed remove action from deleting a newer update.
    @discardableResult
    public func removeManagedRecord(
        id: String,
        expectedPreviousRecord: BrowserWebExtensionManagedRecord,
        in directory: URL
    ) throws -> Bool {
        var ledger = try managementLedger(in: directory)
        guard ledger.records[id] == expectedPreviousRecord else { return false }
        ledger.records.removeValue(forKey: id)
        try writeManagementLedger(ledger, in: directory)
        return true
    }

    /// Resolves every enabled ledger record without exposing filesystem errors.
    /// Package bytes are authenticated later, immediately before WebKit load.
    public func managedInstallations(
        in directory: URL
    ) throws -> BrowserWebExtensionManagedDiscovery {
        let ledger = try managementLedger(in: directory)
        var installations: [BrowserWebExtensionManagedDiscovery.Installation] = []
        var failures: [BrowserWebExtensionManagedDiscovery.Failure] = []
        for record in ledger.records.values.sorted(by: { $0.id < $1.id }) where record.isEnabled {
            let resourceURL: URL
            switch record.source {
            case .directory(let filename, _),
                 .catalogArchive(let filename, _, _):
                let candidate = directory.appendingPathComponent(filename)
                guard candidate.standardizedFileURL.deletingLastPathComponent()
                        == directory.standardizedFileURL,
                      FileManager.default.fileExists(atPath: candidate.path) else {
                    failures.append(.init(recordID: record.id, entryName: filename))
                    continue
                }
                // Integrity is checked exactly once, immediately before
                // WKWebExtension reads this package. Discovery only resolves
                // the ledger path so startup does not hash every package twice.
                resourceURL = candidate
            case .safariApp(let reference):
                resourceURL = reference.bundleURL
            }
            installations.append(.init(record: record, resourceURL: resourceURL))
        }
        return BrowserWebExtensionManagedDiscovery(
            installations: installations,
            failures: failures
        )
    }

    /// Returns the bounded digest used by the management ledger.
    public func digestForManagedPackage(at candidate: URL) throws -> String {
#if DEBUG
        managedPackageDigestRequestCount += 1
#endif
        return try packageDigest(for: candidate)
    }

#if DEBUG
    public func managedPackageDigestRequestCountForTesting() -> Int {
        managedPackageDigestRequestCount
    }
#endif

    private func requireActive() throws {
        guard !isShutDown else { throw CancellationError() }
        try Task.checkCancellation()
    }

    public func validatePackageSize(at candidate: URL) throws {
        try requireActive()
        _ = try validatedPackageEntries(at: candidate)
    }

    public func resolveInstallSource(
        at source: URL,
        archivePolicy: BrowserWebExtensionArchivePolicy = .reject
    ) throws -> BrowserWebExtensionInstallSource {
        try requireActive()
        let sourceValues = try source.resourceValues(
            forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        )
        guard sourceValues.isSymbolicLink != true else {
            throw BrowserWebExtensionInstallError.symbolicLinksNotAllowed
        }
        guard sourceValues.isDirectory == true || sourceValues.isRegularFile == true else {
            throw BrowserWebExtensionInstallError.invalidPackage(source.lastPathComponent)
        }

        guard sourceValues.isDirectory == true else {
            let extensionName = source.pathExtension.lowercased()
            guard extensionName == "zip" || extensionName == "xpi" else {
                throw BrowserWebExtensionInstallError.invalidPackage(source.lastPathComponent)
            }
            switch archivePolicy {
            case .reject:
                throw BrowserWebExtensionInstallError.compressedPackagesNotAllowed
            case .verifiedCatalog(let expectedSHA256, let limits):
                let archiveData = try readBoundedRegularFile(
                    at: source,
                    maximumByteCount: limits.maximumCompressedByteCount
                )
                let archiveDigest = Self.hexDigest(SHA256.hash(data: archiveData))
                guard archiveDigest.caseInsensitiveCompare(expectedSHA256) == .orderedSame else {
                    throw BrowserWebExtensionInstallError.integrityMismatch
                }
                try BrowserWebExtensionArchivePreflight().validate(
                    archiveData,
                    packageName: source.lastPathComponent,
                    limits: limits
                )
            }
            return .managedPackage(
                packageURL: source,
                installationName: source.lastPathComponent
            )
        }
        if FileManager.default.fileExists(
            atPath: source.appendingPathComponent("manifest.json").path
        ) {
            return .managedPackage(
                packageURL: source,
                installationName: source.lastPathComponent
            )
        }

        switch source.pathExtension.lowercased() {
        case "appex":
            return try safariExtensionSource(in: source)
        case "app":
            let plugins = source.appendingPathComponent("Contents/PlugIns", isDirectory: true)
            guard FileManager.default.fileExists(atPath: plugins.path) else {
                throw BrowserWebExtensionInstallError.safariExtensionNotFound(source.lastPathComponent)
            }
            let candidates = try (FileManager.default.contentsOfDirectory(
                at: plugins,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )).filter { $0.pathExtension.lowercased() == "appex" }
            let safariSources = try candidates.compactMap { candidate in
                try safariExtensionSourceIfPresent(in: candidate)
            }
            guard !safariSources.isEmpty else {
                throw BrowserWebExtensionInstallError.safariExtensionNotFound(source.lastPathComponent)
            }
            guard safariSources.count == 1 else {
                throw BrowserWebExtensionInstallError.multipleSafariExtensions(source.lastPathComponent)
            }
            return safariSources[0]
        default:
            throw BrowserWebExtensionInstallError.invalidPackage(source.lastPathComponent)
        }
    }

    public func installCandidate(
        from source: URL,
        into directory: URL,
        destinationName: String? = nil
    ) throws -> URL {
        try requireActive()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let resolvedDestinationName = destinationName ?? source.lastPathComponent
        let destination = directory.appendingPathComponent(
            resolvedDestinationName,
            isDirectory: source.hasDirectoryPath
        )
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw BrowserWebExtensionInstallError.alreadyInstalled(resolvedDestinationName)
        }
        let stagingName = ".cmux-install-\(UUID().uuidString)"
            + (source.pathExtension.isEmpty ? "" : ".\(source.pathExtension)")
        let staging = directory.appendingPathComponent(
            stagingName,
            isDirectory: source.hasDirectoryPath
        )
        defer { try? FileManager.default.removeItem(at: staging) }
        let entries = try validatedPackageEntries(at: source)
        try copyPackage(from: source, entries: entries, to: staging)
        try requireActive()
        try FileManager.default.moveItem(at: staging, to: destination)
        return destination
    }

    /// Copies a validated package to an immutable content-addressed destination.
    ///
    /// A new version never overwrites bytes referenced by the current ledger.
    /// Callers can therefore validate and load the new package, atomically
    /// switch the ledger, then remove the old unreferenced package without a
    /// crash-recovery journal.
    public func installImmutableCandidate(
        from source: URL,
        into directory: URL
    ) throws -> BrowserWebExtensionInstalledPackage {
        try requireActive()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sourceDigest = try packageDigest(for: source)
        let suffix = source.hasDirectoryPath || source.pathExtension.isEmpty
            ? ""
            : ".\(Self.sanitizedPathExtension(source.pathExtension))"
        let destinationName = Self.managedPackagePrefix + sourceDigest + suffix
        let destination = directory.appendingPathComponent(
            destinationName,
            isDirectory: source.hasDirectoryPath
        )
        if FileManager.default.fileExists(atPath: destination.path) {
            guard try packageDigest(for: destination) == sourceDigest else {
                throw BrowserWebExtensionInstallError.integrityMismatch
            }
            return BrowserWebExtensionInstalledPackage(url: destination, digest: sourceDigest)
        }
        let staging = directory.appendingPathComponent(
            Self.stagingPackagePrefix + UUID().uuidString + suffix,
            isDirectory: source.hasDirectoryPath
        )
        defer { try? FileManager.default.removeItem(at: staging) }
        let entries = try validatedPackageEntries(at: source)
        try copyPackage(from: source, entries: entries, to: staging)
        try requireActive()
        guard try packageDigest(for: staging) == sourceDigest else {
            throw BrowserWebExtensionInstallError.integrityMismatch
        }
        do {
            try FileManager.default.moveItem(at: staging, to: destination)
            return BrowserWebExtensionInstalledPackage(url: destination, digest: sourceDigest)
        } catch {
            // Another process may have installed the same immutable bytes.
            if FileManager.default.fileExists(atPath: destination.path),
               try packageDigest(for: destination) == sourceDigest {
                return BrowserWebExtensionInstalledPackage(url: destination, digest: sourceDigest)
            }
            throw error
        }
    }

    /// Removes an immutable package only when no ledger record references it.
    public func removeManagedPackageIfUnreferenced(
        at packageURL: URL,
        in directory: URL
    ) throws {
        try requireActive()
        let managedDirectory = directory.standardizedFileURL
        let candidate = packageURL.standardizedFileURL
        guard candidate.deletingLastPathComponent() == managedDirectory,
              candidate.lastPathComponent.hasPrefix(Self.managedPackagePrefix) else {
            return
        }
        let referencedNames = Set(try managementLedger(in: directory).records.values.compactMap {
            switch $0.source {
            case .directory(let filename, _), .catalogArchive(let filename, _, _):
                return filename
            case .safariApp:
                return nil
            }
        })
        guard !referencedNames.contains(candidate.lastPathComponent) else { return }
        try? FileManager.default.removeItem(at: candidate)
    }

    /// Deletes abandoned staging and content-addressed packages after reading
    /// the authoritative ledger. User-managed folders are never touched.
    public func removeUnreferencedManagedPackages(in directory: URL) throws {
        try requireActive()
        let referencedNames = Set(try managementLedger(in: directory).records.values.compactMap {
            switch $0.source {
            case .directory(let filename, _), .catalogArchive(let filename, _, _):
                return filename
            case .safariApp:
                return nil
            }
        })
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        )) ?? []
        for candidate in contents {
            try requireActive()
            let name = candidate.lastPathComponent
            if name.hasPrefix(Self.stagingPackagePrefix)
                || (name.hasPrefix(Self.managedPackagePrefix) && !referencedNames.contains(name)) {
                try? FileManager.default.removeItem(at: candidate)
            }
        }
    }

    private static func sanitizedPathExtension(_ pathExtension: String) -> String {
        pathExtension.unicodeScalars.compactMap { scalar in
            CharacterSet.alphanumerics.contains(scalar) ? String(scalar).lowercased() : nil
        }.joined()
    }

    private func safariExtensionSource(in appex: URL) throws -> BrowserWebExtensionInstallSource {
        guard let source = try safariExtensionSourceIfPresent(in: appex) else {
            throw BrowserWebExtensionInstallError.safariExtensionNotFound(appex.lastPathComponent)
        }
        return source
    }

    private func safariExtensionSourceIfPresent(
        in appex: URL
    ) throws -> BrowserWebExtensionInstallSource? {
        try requireActive()
        let appexValues = try appex.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard appexValues.isSymbolicLink != true else {
            throw BrowserWebExtensionInstallError.symbolicLinksNotAllowed
        }
        guard appexValues.isDirectory == true else { return nil }
        let bundleDescriptor = try openDirectoryDescriptor(at: appex)
        defer { Darwin.close(bundleDescriptor) }
        let infoData = try readBoundedRegularFile(
            relativePath: "Contents/Info.plist",
            directoryDescriptor: bundleDescriptor,
            packageName: appex.lastPathComponent,
            maximumByteCount: Self.maximumInfoPlistByteCount
        )
        guard let info = try PropertyListSerialization.propertyList(
                from: infoData,
                options: [],
                format: nil
              ) as? [String: Any],
              let extensionDictionary = info["NSExtension"] as? [String: Any],
              extensionDictionary["NSExtensionPointIdentifier"] as? String
                == "com.apple.Safari.web-extension" else {
            return nil
        }
        let resources = appex.appendingPathComponent("Contents/Resources", isDirectory: true)
        let resourceValues = try resources.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard resourceValues.isSymbolicLink != true else {
            throw BrowserWebExtensionInstallError.symbolicLinksNotAllowed
        }
        let manifestHandle = try openRegularFile(
            relativePath: "Contents/Resources/manifest.json",
            directoryDescriptor: bundleDescriptor,
            packageName: appex.lastPathComponent
        )
        try manifestHandle.close()
        guard resourceValues.isDirectory == true,
              let bundleIdentifier = info["CFBundleIdentifier"] as? String else {
            throw BrowserWebExtensionInstallError.invalidPackage(appex.lastPathComponent)
        }
        let installationName = Self.sanitizedInstallationName(bundleIdentifier)
        guard !installationName.isEmpty else {
            throw BrowserWebExtensionInstallError.invalidPackage(appex.lastPathComponent)
        }
        return .appExtensionBundle(.init(
            bundleURL: appex.standardizedFileURL,
            bundleIdentifier: bundleIdentifier,
            installationName: installationName
        ))
    }

    private static func sanitizedInstallationName(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        return name.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? String(scalar) : "-"
        }.joined()
    }

    private func packageDigest(for candidate: URL) throws -> String {
        let entries = try validatedPackageEntries(at: candidate)
        let files = entries.compactMap { entry -> PackageEntry? in
            if case .regularFile = entry.kind { return entry }
            return nil
        }.sorted {
            $0.relativePath.utf8.lexicographicallyPrecedes($1.relativePath.utf8)
        }
        let isSingleFile = entries.count == 1 && entries[0].relativePath.isEmpty
        let directoryDescriptor = isSingleFile ? nil : try openDirectoryDescriptor(at: candidate)
        defer {
            if let directoryDescriptor { Darwin.close(directoryDescriptor) }
        }

        // A single regular-file package uses the standard raw SHA-256 expected
        // by catalog metadata. Directory trees use package digest format v1:
        //   domain || BE32(version) || BE64(file count) ||
        //   repeated(BE64(path byte count) || UTF-8 path ||
        //            BE64(file byte count) || file bytes)
        // Every variable-length field is length-framed so file bytes cannot be
        // reinterpreted as another path. Empty directories intentionally do not
        // affect the digest because they cannot change WebExtension behavior.
        var hasher = SHA256()
        if !isSingleFile {
            hasher.update(data: Self.packageDigestDomain)
            hasher.update(data: Self.bigEndianBytes(Self.packageDigestFormatVersion))
            hasher.update(data: Self.bigEndianBytes(UInt64(files.count)))
        }
        var actualByteCount = 0
        for entry in files {
            try requireActive()
            let pathBytes = Data(entry.relativePath.utf8)
            if !isSingleFile {
                hasher.update(data: Self.bigEndianBytes(UInt64(pathBytes.count)))
                hasher.update(data: pathBytes)
            }
            do {
                let handle: FileHandle
                if let directoryDescriptor {
                    handle = try openRegularFile(
                        relativePath: entry.relativePath,
                        directoryDescriptor: directoryDescriptor,
                        packageName: candidate.lastPathComponent
                    )
                } else {
                    handle = try openRegularFile(at: entry.sourceURL)
                }
                defer { try? handle.close() }
                var status = stat()
                guard Darwin.fstat(handle.fileDescriptor, &status) == 0,
                      status.st_size >= 0 else {
                    throw BrowserWebExtensionInstallError.invalidPackage(
                        candidate.lastPathComponent
                    )
                }
                let expectedFileByteCount = UInt64(status.st_size)
                guard expectedFileByteCount <= UInt64(packageLimits.maximumByteCount) else {
                    throw BrowserWebExtensionInstallError.packageTooLarge
                }
                if !isSingleFile {
                    hasher.update(data: Self.bigEndianBytes(expectedFileByteCount))
                }
                var fileByteCount: UInt64 = 0
                while let chunk = try handle.read(upToCount: Self.copyChunkByteCount), !chunk.isEmpty {
                    try requireActive()
                    actualByteCount = try checkedByteCount(adding: chunk.count, to: actualByteCount)
                    let chunkByteCount = UInt64(chunk.count)
                    guard fileByteCount <= expectedFileByteCount,
                          chunkByteCount <= expectedFileByteCount - fileByteCount else {
                        throw BrowserWebExtensionInstallError.invalidPackage(
                            candidate.lastPathComponent
                        )
                    }
                    fileByteCount += chunkByteCount
                    hasher.update(data: chunk)
                }
                guard fileByteCount == expectedFileByteCount else {
                    throw BrowserWebExtensionInstallError.invalidPackage(
                        candidate.lastPathComponent
                    )
                }
            }
        }
        return Self.hexDigest(hasher.finalize())
    }

    private func validatedPackageEntries(at candidate: URL) throws -> [PackageEntry] {
        try requireActive()
        let rootValues = try candidate.resourceValues(
            forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        )
        guard rootValues.isSymbolicLink != true else {
            throw BrowserWebExtensionInstallError.symbolicLinksNotAllowed
        }
        if rootValues.isDirectory != true {
            guard rootValues.isRegularFile == true,
                  let fileSize = rootValues.fileSize,
                  fileSize >= 0 else {
                throw BrowserWebExtensionInstallError.invalidPackage(candidate.lastPathComponent)
            }
            _ = try checkedByteCount(adding: fileSize, to: 0)
            return [PackageEntry(
                sourceURL: candidate,
                relativePath: "",
                kind: .regularFile
            )]
        }

        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ]
        // Foundation can canonicalize system-parent symlinks (for example
        // `/var` to `/private/var`) in enumerated child URLs. Derive relative
        // paths from the same canonical root instead of subtracting the input
        // path's byte count.
        let enumerationRoot = try canonicalExistingDirectoryURL(candidate)
        guard let enumerator = FileManager.default.enumerator(
            at: enumerationRoot,
            includingPropertiesForKeys: Array(keys),
            options: []
        ) else {
            throw BrowserWebExtensionInstallError.invalidPackage(candidate.lastPathComponent)
        }

        var entries: [PackageEntry] = []
        var entryCount = 0
        var declaredByteCount = 0
        for case let entryURL as URL in enumerator {
            try requireActive()
            entryCount += 1
            guard entryCount <= packageLimits.maximumFileCount else {
                throw BrowserWebExtensionInstallError.packageContainsTooManyFiles
            }
            let values = try entryURL.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true {
                throw BrowserWebExtensionInstallError.symbolicLinksNotAllowed
            }
            let relativePath = String(entryURL.path.dropFirst(enumerationRoot.path.count + 1))
            if values.isDirectory == true {
                entries.append(PackageEntry(
                    sourceURL: entryURL,
                    relativePath: relativePath,
                    kind: .directory
                ))
                continue
            }
            guard values.isRegularFile == true,
                  let fileSize = values.fileSize,
                  fileSize >= 0 else {
                throw BrowserWebExtensionInstallError.invalidPackage(candidate.lastPathComponent)
            }
            declaredByteCount = try checkedByteCount(adding: fileSize, to: declaredByteCount)
            entries.append(PackageEntry(
                sourceURL: entryURL,
                relativePath: relativePath,
                kind: .regularFile
            ))
        }
        return entries
    }

    private func canonicalExistingDirectoryURL(_ url: URL) throws -> URL {
        let canonicalPath = url.path.withCString { pathPointer -> String? in
            guard let resolvedPointer = Darwin.realpath(pathPointer, nil) else { return nil }
            defer { Darwin.free(resolvedPointer) }
            return String(cString: resolvedPointer)
        }
        guard let canonicalPath else {
            throw packageOpenError(packageName: url.lastPathComponent)
        }
        return URL(fileURLWithPath: canonicalPath, isDirectory: true)
    }

    private func checkedByteCount(adding byteCount: Int, to total: Int) throws -> Int {
        guard byteCount >= 0,
              total <= packageLimits.maximumByteCount - byteCount else {
            throw BrowserWebExtensionInstallError.packageTooLarge
        }
        return total + byteCount
    }

    private func copyPackage(
        from source: URL,
        entries: [PackageEntry],
        to destination: URL
    ) throws {
        try requireActive()
        if entries.count == 1,
           entries[0].relativePath.isEmpty,
           case .regularFile = entries[0].kind {
            var copiedByteCount = 0
            let input = try openRegularFile(at: source)
            defer { try? input.close() }
            try copyRegularFile(
                from: input,
                sourceName: source.lastPathComponent,
                to: destination,
                cumulativeByteCount: &copiedByteCount
            )
            return
        }

        let sourceDirectoryDescriptor = try openDirectoryDescriptor(at: source)
        defer { Darwin.close(sourceDirectoryDescriptor) }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        var copiedEntryCount = 0
        var copiedByteCount = 0
        for entry in entries.sorted(by: { $0.relativePath < $1.relativePath }) {
            try requireActive()
            copiedEntryCount += 1
            guard copiedEntryCount <= packageLimits.maximumFileCount else {
                throw BrowserWebExtensionInstallError.packageContainsTooManyFiles
            }
            let destinationURL = destination.appendingPathComponent(entry.relativePath)
            switch entry.kind {
            case .directory:
                try FileManager.default.createDirectory(
                    at: destinationURL,
                    withIntermediateDirectories: true
                )
            case .regularFile:
                try FileManager.default.createDirectory(
                    at: destinationURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                do {
                    let input = try openRegularFile(
                        relativePath: entry.relativePath,
                        directoryDescriptor: sourceDirectoryDescriptor,
                        packageName: source.lastPathComponent
                    )
                    defer { try? input.close() }
                    try copyRegularFile(
                        from: input,
                        sourceName: entry.sourceURL.lastPathComponent,
                        to: destinationURL,
                        cumulativeByteCount: &copiedByteCount
                    )
                }
            }
        }
    }

    private func copyRegularFile(
        from input: FileHandle,
        sourceName: String,
        to destination: URL,
        cumulativeByteCount: inout Int
    ) throws {
        try requireActive()
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw BrowserWebExtensionInstallError.invalidPackage(sourceName)
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        while let chunk = try input.read(upToCount: Self.copyChunkByteCount), !chunk.isEmpty {
            try requireActive()
            cumulativeByteCount = try checkedByteCount(
                adding: chunk.count,
                to: cumulativeByteCount
            )
            try output.write(contentsOf: chunk)
        }
    }

    private func openDirectoryDescriptor(at url: URL) throws -> Int32 {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw packageOpenError(packageName: url.lastPathComponent)
        }
        return descriptor
    }

    private func openRegularFile(at url: URL) throws -> FileHandle {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw packageOpenError(packageName: url.lastPathComponent)
        }
        return try regularFileHandle(
            descriptor: descriptor,
            packageName: url.lastPathComponent
        )
    }

    private func openRegularFile(
        relativePath: String,
        directoryDescriptor: Int32,
        packageName: String
    ) throws -> FileHandle {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty,
              components.allSatisfy({ $0 != "." && $0 != ".." }) else {
            throw BrowserWebExtensionInstallError.invalidPackage(packageName)
        }
        var currentDirectoryDescriptor = Darwin.dup(directoryDescriptor)
        guard currentDirectoryDescriptor >= 0 else {
            throw BrowserWebExtensionInstallError.invalidPackage(packageName)
        }
        defer { Darwin.close(currentDirectoryDescriptor) }

        for component in components.dropLast() {
            let nextDescriptor = String(component).withCString {
                Darwin.openat(
                    currentDirectoryDescriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard nextDescriptor >= 0 else {
                throw packageOpenError(packageName: packageName)
            }
            Darwin.close(currentDirectoryDescriptor)
            currentDirectoryDescriptor = nextDescriptor
        }

        let descriptor = String(components[components.index(before: components.endIndex)]).withCString {
            Darwin.openat(
                currentDirectoryDescriptor,
                $0,
                O_RDONLY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            throw packageOpenError(packageName: packageName)
        }
        return try regularFileHandle(descriptor: descriptor, packageName: packageName)
    }

    private func readBoundedRegularFile(
        relativePath: String,
        directoryDescriptor: Int32,
        packageName: String,
        maximumByteCount: Int
    ) throws -> Data {
        let handle = try openRegularFile(
            relativePath: relativePath,
            directoryDescriptor: directoryDescriptor,
            packageName: packageName
        )
        defer { try? handle.close() }
        var data = Data()
        while let chunk = try handle.read(upToCount: Self.copyChunkByteCount), !chunk.isEmpty {
            try requireActive()
            guard data.count <= maximumByteCount - chunk.count else {
                throw BrowserWebExtensionInstallError.packageTooLarge
            }
            data.append(chunk)
        }
        return data
    }

    private func readBoundedRegularFile(
        at url: URL,
        maximumByteCount: Int
    ) throws -> Data {
        let handle = try openRegularFile(at: url)
        defer { try? handle.close() }
        var data = Data()
        while let chunk = try handle.read(upToCount: Self.copyChunkByteCount), !chunk.isEmpty {
            try requireActive()
            guard chunk.count <= maximumByteCount,
                  data.count <= maximumByteCount - chunk.count else {
                throw BrowserWebExtensionInstallError.packageTooLarge
            }
            data.append(chunk)
        }
        return data
    }

    private func regularFileHandle(descriptor: Int32, packageName: String) throws -> FileHandle {
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            Darwin.close(descriptor)
            throw BrowserWebExtensionInstallError.invalidPackage(packageName)
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private func packageOpenError(packageName: String) -> BrowserWebExtensionInstallError {
        if errno == ELOOP { return .symbolicLinksNotAllowed }
        return .invalidPackage(packageName)
    }

    private static func hexDigest<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func bigEndianBytes<T: FixedWidthInteger>(_ value: T) -> Data {
        var encoded = value.bigEndian
        return Swift.withUnsafeBytes(of: &encoded) { Data($0) }
    }
}

public enum BrowserWebExtensionInstallError: LocalizedError, Equatable {
    case alreadyInstalled(String)
    case outsideManagedDirectory
    case symbolicLinksNotAllowed
    case invalidPackage(String)
    case safariExtensionNotFound(String)
    case multipleSafariExtensions(String)
    case packageTooLarge
    case packageContainsTooManyFiles
    case compressedPackagesNotAllowed
    case integrityMismatch
    case unsupportedManagementSchema
    case managementLedgerTooLarge
    case installPreviewExpired

    public var errorDescription: String? {
        switch self {
        case .alreadyInstalled(let name):
            return String(
                localized: "browser.extensions.install.alreadyInstalled",
                defaultValue: "\(name) is already installed."
            )
        case .outsideManagedDirectory:
            return String(
                localized: "browser.extensions.install.outsideManagedDirectory",
                defaultValue: "The extension must be inside the managed extensions directory."
            )
        case .symbolicLinksNotAllowed:
            return String(
                localized: "browser.extensions.install.symbolicLinksNotAllowed",
                defaultValue: "Extensions containing symbolic links cannot be installed."
            )
        case .invalidPackage(let name):
            return String(
                localized: "browser.extensions.install.invalidPackage",
                defaultValue: "\(name) is not a readable extension package."
            )
        case .safariExtensionNotFound(let name):
            return String(
                localized: "browser.extensions.install.safariExtensionNotFound",
                defaultValue: "\(name) does not contain a Safari web extension."
            )
        case .multipleSafariExtensions(let name):
            return String(
                localized: "browser.extensions.install.multipleSafariExtensions",
                defaultValue: "\(name) contains more than one Safari web extension. Choose an extension bundle directly."
            )
        case .packageTooLarge:
            return String(
                localized: "browser.extensions.install.tooLarge",
                defaultValue: "The installed extension is larger than 256 MB."
            )
        case .packageContainsTooManyFiles:
            return String(
                localized: "browser.extensions.install.tooManyFiles",
                defaultValue: "The extension package contains too many files."
            )
        case .compressedPackagesNotAllowed:
            return String(
                localized: "browser.extensions.install.compressedNotAllowed",
                defaultValue: "Choose an unpacked extension folder. ZIP and XPI imports are accepted only from the verified catalog."
            )
        case .integrityMismatch:
            return String(
                localized: "browser.extensions.store.error.integrity",
                defaultValue: "The extension package failed its integrity check."
            )
        case .unsupportedManagementSchema:
            return String(
                localized: "browser.extensions.install.managementSchema",
                defaultValue: "The saved extension settings use an unsupported format."
            )
        case .managementLedgerTooLarge:
            return String(
                localized: "browser.extensions.install.managementLedgerTooLarge",
                defaultValue: "The saved extension settings are too large."
            )
        case .installPreviewExpired:
            return String(
                localized: "browser.extensions.install.previewExpired",
                defaultValue: "The extension install confirmation expired. Review the extension again."
            )
        }
    }
}
