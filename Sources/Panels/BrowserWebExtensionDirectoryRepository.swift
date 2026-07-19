import CryptoKit
import Darwin
import Foundation

struct BrowserWebExtensionApprovalDiscoveryResult: Sendable {
    struct Failure: Sendable {
        let url: URL
        let message: String
    }

    let candidates: [URL]
    let appExtensionReferences: [BrowserWebExtensionAppExtensionReference]
    let failures: [Failure]
}

struct BrowserWebExtensionAppExtensionReference: Codable, Equatable, Sendable {
    let bundleURL: URL
    let bundleIdentifier: String
    let installationName: String
}

enum BrowserWebExtensionInstallSource: Sendable {
    case managedPackage(packageURL: URL, installationName: String)
    case appExtensionBundle(BrowserWebExtensionAppExtensionReference)
}

/// Moves extension-directory enumeration and metadata reads off the main actor.
@available(macOS 15.4, *)
actor BrowserWebExtensionDirectoryRepository {
    struct PackageLimits: Sendable {
        // Catalog downloads stay capped at 25 MB of compressed data. Installed
        // packages need a separate limit because production extensions such as
        // Bitwarden expand well beyond that while remaining bounded on disk.
        static let standard = PackageLimits(
            maximumByteCount: 256 * 1024 * 1024,
            maximumFileCount: 10_000
        )

        let maximumByteCount: Int
        let maximumFileCount: Int

        init(maximumByteCount: Int, maximumFileCount: Int) {
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

    private static let approvalFileName = ".cmux-approved-extensions.json"
    private static let appExtensionReferencesFileName = ".cmux-app-extension-bundles.json"
    private static let toolbarPinsFileName = ".cmux-toolbar-pins.json"
    private static let copyChunkByteCount = 1024 * 1024
    private let packageLimits: PackageLimits
    private var isShutDown = false

    init(packageLimits: PackageLimits = .standard) {
        self.packageLimits = packageLimits
    }

    func shutdownAndRemoveDirectory(_ directory: URL) {
        isShutDown = true
        try? FileManager.default.removeItem(at: directory)
    }

    private func requireActive() throws {
        guard !isShutDown else { throw CancellationError() }
        try Task.checkCancellation()
    }

    func candidateURLs(in directory: URL) -> [URL] {
        BrowserWebExtensionsManager.candidateURLs(in: directory)
    }

    func approvedCandidateURLs(in directory: URL) throws -> BrowserWebExtensionApprovalDiscoveryResult {
        try requireActive()
        let approvals = try readApprovals(in: directory)
        var candidates: [URL] = []
        var failures: [BrowserWebExtensionApprovalDiscoveryResult.Failure] = []
        for candidate in candidateURLs(in: directory) {
            guard let approvedDigest = approvals[candidate.lastPathComponent] else { continue }
            do {
                if try packageDigest(for: candidate) == approvedDigest {
                    candidates.append(candidate)
                }
            } catch {
                failures.append(.init(url: candidate, message: error.localizedDescription))
            }
        }
        return BrowserWebExtensionApprovalDiscoveryResult(
            candidates: candidates,
            appExtensionReferences: try readAppExtensionReferences(in: directory),
            failures: failures
        )
    }

    func approveCandidate(at candidate: URL, in directory: URL) throws {
        try requireActive()
        let managedDirectory = directory.standardizedFileURL
        guard candidate.standardizedFileURL.deletingLastPathComponent() == managedDirectory else {
            throw BrowserWebExtensionInstallError.outsideManagedDirectory
        }
        var approvals = try readApprovals(in: directory)
        approvals[candidate.lastPathComponent] = try packageDigest(for: candidate)
        try writeApprovals(approvals, in: directory)
    }

    func validatePackageSize(at candidate: URL) throws {
        try requireActive()
        _ = try validatedPackageEntries(at: candidate)
    }

    func resolveInstallSource(at source: URL) throws -> BrowserWebExtensionInstallSource {
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
            return .managedPackage(
                packageURL: source,
                installationName: source.lastPathComponent
            )
        }
    }

    func installCandidate(
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
        let infoURL = appex.appendingPathComponent("Contents/Info.plist")
        let infoValues = try infoURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        guard infoValues.isSymbolicLink != true else {
            throw BrowserWebExtensionInstallError.symbolicLinksNotAllowed
        }
        guard infoValues.isRegularFile == true,
              let info = try PropertyListSerialization.propertyList(
                from: Data(contentsOf: infoURL),
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
        guard resourceValues.isDirectory == true,
              FileManager.default.fileExists(
                atPath: resources.appendingPathComponent("manifest.json").path
              ),
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

    func removeInstalledCandidate(at url: URL, from directory: URL) {
        try? FileManager.default.removeItem(at: url)
        guard !isShutDown else { return }
        guard var approvals = try? readApprovals(in: directory) else { return }
        approvals.removeValue(forKey: url.lastPathComponent)
        try? writeApprovals(approvals, in: directory)
    }

    func approveAppExtensionReference(
        _ reference: BrowserWebExtensionAppExtensionReference,
        in directory: URL
    ) throws {
        try requireActive()
        var references = try readAppExtensionReferences(in: directory)
        guard !references.contains(where: { $0.bundleIdentifier == reference.bundleIdentifier }) else {
            throw BrowserWebExtensionInstallError.alreadyInstalled(reference.installationName)
        }
        references.append(reference)
        try writeAppExtensionReferences(references, in: directory)
    }

    func removeAppExtensionReference(
        _ reference: BrowserWebExtensionAppExtensionReference,
        from directory: URL
    ) {
        guard !isShutDown,
              var references = try? readAppExtensionReferences(in: directory) else { return }
        references.removeAll { $0.bundleIdentifier == reference.bundleIdentifier }
        try? writeAppExtensionReferences(references, in: directory)
    }

    func toolbarPinnedExtensionIdentifiers(in directory: URL) throws -> Set<String> {
        try requireActive()
        let url = directory.appendingPathComponent(Self.toolbarPinsFileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return Set(try JSONDecoder().decode([String].self, from: Data(contentsOf: url)))
    }

    func setToolbarActionPinned(
        _ isPinned: Bool,
        uniqueIdentifier: String,
        in directory: URL
    ) throws -> Set<String> {
        try requireActive()
        var identifiers = try toolbarPinnedExtensionIdentifiers(in: directory)
        if isPinned {
            identifiers.insert(uniqueIdentifier)
        } else {
            identifiers.remove(uniqueIdentifier)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(identifiers.sorted())
        try data.write(
            to: directory.appendingPathComponent(Self.toolbarPinsFileName),
            options: .atomic
        )
        return identifiers
    }

    private func readApprovals(in directory: URL) throws -> [String: String] {
        let url = directory.appendingPathComponent(Self.approvalFileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        return try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
    }

    private func writeApprovals(_ approvals: [String: String], in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(approvals)
        try data.write(
            to: directory.appendingPathComponent(Self.approvalFileName),
            options: .atomic
        )
    }

    private func readAppExtensionReferences(
        in directory: URL
    ) throws -> [BrowserWebExtensionAppExtensionReference] {
        let url = directory.appendingPathComponent(Self.appExtensionReferencesFileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode(
            [BrowserWebExtensionAppExtensionReference].self,
            from: Data(contentsOf: url)
        )
    }

    private func writeAppExtensionReferences(
        _ references: [BrowserWebExtensionAppExtensionReference],
        in directory: URL
    ) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(references.sorted {
            $0.bundleIdentifier < $1.bundleIdentifier
        })
        try data.write(
            to: directory.appendingPathComponent(Self.appExtensionReferencesFileName),
            options: .atomic
        )
    }

    private func packageDigest(for candidate: URL) throws -> String {
        let entries = try validatedPackageEntries(at: candidate)
        let files = entries.compactMap { entry -> PackageEntry? in
            if case .regularFile = entry.kind { return entry }
            return nil
        }.sorted { $0.relativePath < $1.relativePath }
        let isSingleFile = entries.count == 1 && entries[0].relativePath.isEmpty
        let directoryDescriptor = isSingleFile ? nil : try openDirectoryDescriptor(at: candidate)
        defer {
            if let directoryDescriptor { Darwin.close(directoryDescriptor) }
        }
        var hasher = SHA256()
        var actualByteCount = 0
        for entry in files {
            try requireActive()
            if entries.count > 1 || entries.first?.relativePath.isEmpty == false {
                hasher.update(data: Data(entry.relativePath.utf8))
                hasher.update(data: Data([0]))
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
                while let chunk = try handle.read(upToCount: Self.copyChunkByteCount), !chunk.isEmpty {
                    try requireActive()
                    actualByteCount = try checkedByteCount(adding: chunk.count, to: actualByteCount)
                    hasher.update(data: chunk)
                }
            }
            if !entry.relativePath.isEmpty { hasher.update(data: Data([0])) }
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
        guard let enumerator = FileManager.default.enumerator(
            at: candidate,
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
            let relativePath = String(entryURL.path.dropFirst(candidate.path.count + 1))
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
}

enum BrowserWebExtensionInstallError: LocalizedError {
    case alreadyInstalled(String)
    case outsideManagedDirectory
    case symbolicLinksNotAllowed
    case invalidPackage(String)
    case safariExtensionNotFound(String)
    case multipleSafariExtensions(String)
    case packageTooLarge
    case packageContainsTooManyFiles

    var errorDescription: String? {
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
        }
    }
}
