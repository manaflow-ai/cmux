import CryptoKit
import Darwin
import Foundation

struct SurfaceStatusCodexPresenceInspection: Sendable {
    let state: SurfaceStatusAdapterState
    let destination: URL
}

/// Owns only a launch-attribution helper and one exact .zshrc source block.
/// It never edits Codex hooks/config or cmux's native lifecycle store.
struct SurfaceStatusCodexPresenceManager: Sendable {
    static let sourceComment = "# cmux Surface Status: launch-only Codex attribution\n"
    static let sourceLine = "[[ -r \"$HOME/.config/cmux-surface-status/codex-presence.zsh\" ]] && source \"$HOME/.config/cmux-surface-status/codex-presence.zsh\"\n"
    static let sourceBlock = "\n" + sourceComment + sourceLine

    struct Receipt: Codable, Sendable {
        let schemaVersion: Int
        var enabled: Bool
        var launcherSHA256: String
        var snippetSHA256: String
        var zshrcExisted: Bool?
    }

    private struct Snapshot {
        let url: URL
        let data: Data?
        let permissions: Int
    }

    let homeDirectory: URL
    let stateDirectory: URL
    let launcherBytes: Data
    let snippetBytes: Data

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        stateDirectory: URL? = nil,
        bundle: Bundle = .main,
        launcherBytes: Data? = nil,
        snippetBytes: Data? = nil
    ) throws {
        self.homeDirectory = homeDirectory.standardizedFileURL.resolvingSymlinksInPath()
        self.stateDirectory = stateDirectory?.standardizedFileURL.resolvingSymlinksInPath()
            ?? self.homeDirectory.appending(path: ".local/state/cmux/surface-status-adapters", directoryHint: .isDirectory)
        self.launcherBytes = try launcherBytes ?? Self.load("codex-presence-launcher", "py", bundle: bundle)
        self.snippetBytes = try snippetBytes ?? Self.load("codex-presence", "zsh", bundle: bundle)
    }

    var launcherURL: URL {
        homeDirectory.appending(path: ".local/libexec/cmux-surface-status/codex-presence-launcher.py")
    }
    var snippetURL: URL {
        homeDirectory.appending(path: ".config/cmux-surface-status/codex-presence.zsh")
    }
    var zshrcURL: URL { homeDirectory.appending(path: ".zshrc") }
    var receiptURL: URL { stateDirectory.appending(path: "codex-presence-receipt.json") }
    private var lockURL: URL { stateDirectory.appending(path: "codex-presence-manager.lock") }

    func inspect() throws -> SurfaceStatusCodexPresenceInspection {
        try validateBoundaries()
        guard let receipt = try loadReceipt() else {
            let hasSourceBlock = try sourceBlockCount() > 0
            let hasArtifacts = fileExists(launcherURL) || fileExists(snippetURL) || hasSourceBlock
            return .init(state: hasArtifacts ? .unmanaged : .notInstalled, destination: launcherURL)
        }
        if receipt.enabled {
            let currentLauncher = try hash(launcherURL)
            let currentSnippet = try hash(snippetURL)
            let blockCount = try sourceBlockCount()
            if currentLauncher == receipt.launcherSHA256,
               currentSnippet == receipt.snippetSHA256,
               blockCount == 1 {
                let latest = currentLauncher == Self.hash(launcherBytes) && currentSnippet == Self.hash(snippetBytes)
                return .init(state: latest ? .enabled : .updateAvailable, destination: launcherURL)
            }
            return .init(state: .drifted, destination: launcherURL)
        }
        let hasSourceBlock = try sourceBlockCount() > 0
        let clean = !fileExists(launcherURL) && !fileExists(snippetURL) && !hasSourceBlock
        return .init(state: clean ? .disabled : .drifted, destination: launcherURL)
    }

    func apply(_ operation: SurfaceStatusAdapterOperation) throws -> SurfaceStatusCodexPresenceInspection {
        try validateBoundaries()
        try FileManager.default.createDirectory(
            at: stateDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return try withLock {
            let before = try inspect()
            if before.state == .drifted || before.state == .unmanaged {
                throw before.state == .unmanaged
                    ? SurfaceStatusAdapterManagerError.unmanagedDestination(before.destination)
                    : SurfaceStatusAdapterManagerError.modifiedDestination(before.destination)
            }
            let snapshots = try [launcherURL, snippetURL, zshrcURL, receiptURL].map(snapshot)
            do {
                switch operation {
            case .install:
                if before.state == .enabled { return before }
                let existingReceipt = try loadReceipt()
                let zshrcExisted = existingReceipt?.zshrcExisted ?? fileExists(zshrcURL)
                try installFilesAndBlock()
                try writeReceipt(.init(
                    schemaVersion: 1,
                    enabled: true,
                    launcherSHA256: Self.hash(launcherBytes),
                    snippetSHA256: Self.hash(snippetBytes),
                    zshrcExisted: zshrcExisted
                ))
            case .disable:
                guard let receipt = try loadReceipt() else { throw SurfaceStatusAdapterManagerError.noInstallation }
                if receipt.enabled { try removeOwnedFilesAndBlock(receipt) }
                var disabled = receipt
                disabled.enabled = false
                try writeReceipt(disabled)
            case .enable:
                guard var receipt = try loadReceipt() else { throw SurfaceStatusAdapterManagerError.noInstallation }
                try installFilesAndBlock()
                receipt.enabled = true
                receipt.launcherSHA256 = Self.hash(launcherBytes)
                receipt.snippetSHA256 = Self.hash(snippetBytes)
                try writeReceipt(receipt)
            case .uninstall:
                guard let receipt = try loadReceipt() else { throw SurfaceStatusAdapterManagerError.noInstallation }
                if receipt.enabled { try removeOwnedFilesAndBlock(receipt) }
                try FileManager.default.removeItem(at: receiptURL)
                }
            } catch {
                do {
                    for snapshot in snapshots.reversed() { try restore(snapshot) }
                } catch {
                    throw SurfaceStatusAdapterManagerError.operationFailed(error.localizedDescription)
                }
                throw error
            }
            return try inspect()
        }
    }

    private func installFilesAndBlock() throws {
        let existing: String
        if fileExists(zshrcURL) {
            do {
                existing = try String(contentsOf: zshrcURL, encoding: .utf8)
            } catch {
                throw SurfaceStatusAdapterManagerError.modifiedDestination(zshrcURL)
            }
        } else {
            existing = ""
        }
        let blockCount = existing.countOccurrences(of: Self.sourceBlock)
        guard blockCount <= 1 else {
            throw SurfaceStatusAdapterManagerError.modifiedDestination(zshrcURL)
        }
        try atomicWrite(launcherBytes, to: launcherURL, permissions: 0o755)
        try atomicWrite(snippetBytes, to: snippetURL, permissions: 0o644)
        if blockCount == 0 {
            try atomicWrite(Data((existing + Self.sourceBlock).utf8), to: zshrcURL, permissions: existingMode(zshrcURL, fallback: 0o600))
        }
    }

    private func removeOwnedFilesAndBlock(_ receipt: Receipt) throws {
        guard try hash(launcherURL) == receipt.launcherSHA256,
              try hash(snippetURL) == receipt.snippetSHA256 else {
            throw SurfaceStatusAdapterManagerError.modifiedDestination(launcherURL)
        }
        let text = try String(contentsOf: zshrcURL, encoding: .utf8)
        guard text.countOccurrences(of: Self.sourceBlock) == 1 else {
            throw SurfaceStatusAdapterManagerError.modifiedDestination(zshrcURL)
        }
        guard let blockRange = text.range(of: Self.sourceBlock) else {
            throw SurfaceStatusAdapterManagerError.modifiedDestination(zshrcURL)
        }
        let rewritten = text.replacingCharacters(in: blockRange, with: "")
        if rewritten.isEmpty {
            if receipt.zshrcExisted == false {
                try FileManager.default.removeItem(at: zshrcURL)
            } else {
                try atomicWrite(Data(), to: zshrcURL, permissions: existingMode(zshrcURL, fallback: 0o600))
            }
        } else {
            try atomicWrite(Data(rewritten.utf8), to: zshrcURL, permissions: existingMode(zshrcURL, fallback: 0o600))
        }
        try FileManager.default.removeItem(at: launcherURL)
        try FileManager.default.removeItem(at: snippetURL)
    }

    private func snapshot(_ url: URL) throws -> Snapshot {
        guard fileExists(url) else { return Snapshot(url: url, data: nil, permissions: 0o600) }
        let data = try boundedRegularFileData(at: url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return Snapshot(
            url: url,
            data: data,
            permissions: (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o600
        )
    }

    private func restore(_ snapshot: Snapshot) throws {
        if let data = snapshot.data {
            try atomicWrite(data, to: snapshot.url, permissions: snapshot.permissions)
        } else if fileExists(snapshot.url) {
            try FileManager.default.removeItem(at: snapshot.url)
        }
    }

    private func sourceBlockCount() throws -> Int {
        guard fileExists(zshrcURL) else { return 0 }
        guard let text = String(data: try boundedRegularFileData(at: zshrcURL), encoding: .utf8) else {
            throw SurfaceStatusAdapterManagerError.modifiedDestination(zshrcURL)
        }
        return text.countOccurrences(of: Self.sourceBlock)
    }

    private func loadReceipt() throws -> Receipt? {
        guard fileExists(receiptURL) else { return nil }
        let receipt = try JSONDecoder().decode(Receipt.self, from: boundedRegularFileData(at: receiptURL))
        guard receipt.schemaVersion == 1,
              receipt.launcherSHA256.count == 64,
              receipt.snippetSHA256.count == 64 else {
            throw SurfaceStatusAdapterManagerError.invalidReceipt
        }
        return receipt
    }

    private func writeReceipt(_ receipt: Receipt) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try atomicWrite(encoder.encode(receipt), to: receiptURL, permissions: 0o600)
    }

    private func validateBoundaries() throws {
        for url in [stateDirectory, launcherURL, snippetURL, zshrcURL] {
            guard url.standardizedFileURL.pathComponents.starts(with: homeDirectory.pathComponents),
                  !hasSymlinkComponent(url) else {
                throw SurfaceStatusAdapterManagerError.unsafePath(url)
            }
        }
    }

    private func hasSymlinkComponent(_ url: URL) -> Bool {
        var current = homeDirectory
        for component in url.standardizedFileURL.pathComponents.dropFirst(homeDirectory.pathComponents.count) {
            current.append(path: component)
            var info = stat()
            if lstat(current.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK { return true }
        }
        return false
    }

    private func hash(_ url: URL) throws -> String? {
        guard fileExists(url) else { return nil }
        return Self.hash(try boundedRegularFileData(at: url))
    }

    private func boundedRegularFileData(at url: URL) throws -> Data {
        guard !hasSymlinkComponent(url) else { throw SurfaceStatusAdapterManagerError.unsafePath(url) }
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw SurfaceStatusAdapterManagerError.unsafePath(url) }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_nlink == 1,
              info.st_uid == getuid(),
              info.st_size >= 0,
              info.st_size <= 1_048_576 else {
            throw SurfaceStatusAdapterManagerError.unsafePath(url)
        }
        let data = try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).readToEnd() ?? Data()
        guard data.count == info.st_size else { throw SurfaceStatusAdapterManagerError.unsafePath(url) }
        return data
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func atomicWrite(_ data: Data, to url: URL, permissions: Int) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = parent.appending(path: ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporary, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: temporary.path)
            if fileExists(url) { _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary) }
            else { try FileManager.default.moveItem(at: temporary, to: url) }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        let descriptor = open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw SurfaceStatusAdapterManagerError.operationFailed(String(cString: strerror(errno))) }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_nlink == 1,
              info.st_uid == getuid(),
              fchmod(descriptor, 0o600) == 0 else {
            throw SurfaceStatusAdapterManagerError.unsafePath(lockURL)
        }
        guard flock(descriptor, LOCK_EX) == 0 else { throw SurfaceStatusAdapterManagerError.operationFailed(String(cString: strerror(errno))) }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    private func existingMode(_ url: URL, fallback: Int) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? fallback
    }

    private func fileExists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    private static func load(_ name: String, _ ext: String, bundle: Bundle) throws -> Data {
        guard let url = bundle.url(forResource: name, withExtension: ext, subdirectory: "AdapterPayloads")
                ?? bundle.url(forResource: name, withExtension: ext),
              let data = try? Data(contentsOf: url), !data.isEmpty else {
            throw SurfaceStatusAdapterManagerError.invalidBundledPayload("codex-presence")
        }
        return data
    }
}

private extension String {
    func countOccurrences(of needle: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var range = startIndex..<endIndex
        while let found = self.range(of: needle, range: range) {
            count += 1
            range = found.upperBound..<endIndex
        }
        return count
    }
}
