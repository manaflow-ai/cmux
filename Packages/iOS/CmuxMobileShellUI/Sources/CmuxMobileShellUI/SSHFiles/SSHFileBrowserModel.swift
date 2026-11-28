#if os(iOS)
import CmuxMobileSSH
import CmuxMobileShell
import CmuxMobileSupport
import Foundation
import Observation

/// One SFTP browsing session for an SSH computer (PRD D7).
///
/// Owns a single lazily opened ``SFTPClient`` shared by every directory the
/// sheet shows, reopening it once when the channel was lost (for example
/// after the SSH connection dropped and reconnected). Closing the sheet
/// closes the session and deletes this session's downloaded files.
@MainActor
@Observable
final class SSHFileBrowserModel {
    struct Listing: Equatable {
        var entries: [SFTPEntry]
        var loadedAt: Date
    }

    /// A running upload or download, shown as a determinate progress bar.
    struct Transfer: Equatable {
        enum Kind: Equatable { case upload, download }
        var kind: Kind
        var name: String
        var bytes: UInt64
        var total: UInt64?

        var fraction: Double? {
            guard let total, total > 0 else { return nil }
            return min(1, Double(bytes) / Double(total))
        }
    }

    let hostID: UUID
    @ObservationIgnored private let computers: MobileSSHComputers
    @ObservationIgnored private var client: SFTPClient?
    @ObservationIgnored private var opening: Task<SFTPClient, any Error>?
    @ObservationIgnored let downloadsDirectory: URL

    /// The browser's root folder: the remote home, or `/` when the start
    /// folder lies outside it.
    private(set) var homePath: String?
    private(set) var homeError: String?
    /// Folders between the root and the start folder, outermost first; the
    /// sheet pushes them so the start folder shows with Back walking up.
    private(set) var startTrail: [String] = []
    private(set) var listings: [String: Listing] = [:]
    private(set) var listingErrors: [String: String] = [:]
    private(set) var loadingPaths: Set<String> = []
    private(set) var transfer: Transfer?
    /// A failed action (delete, rename, upload…) waiting to be shown.
    var actionError: String?

    init(hostID: UUID, computers: MobileSSHComputers) {
        self.hostID = hostID
        self.computers = computers
        downloadsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ssh-files", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    var hostName: String {
        computers.host(id: hostID)?.name ?? ""
    }

    // MARK: Session

    /// Resolves the root and, when `startDirectory` names a folder that
    /// exists (the terminal's current directory), the trail down to it.
    func start(startDirectory: (@MainActor () async -> String?)? = nil) async {
        guard homePath == nil else { return }
        homeError = nil
        do {
            let home = try await withClient { try await $0.realpath(".") }
            var start: String?
            if let requested = await startDirectory?(), requested.hasPrefix("/") {
                start = try? await withClient { try await $0.realpath(requested) }
            }
            if let start, await resolvesToDirectory(start) {
                let (root, trail) = Self.trail(from: home, to: start)
                startTrail = trail
                homePath = root
            } else {
                homePath = home
            }
        } catch {
            homeError = Self.describe(error)
        }
    }

    /// The root to show and the folders to push to reach `target`: under
    /// `home` the root is `home`, anywhere else it is `/`.
    nonisolated static func trail(from home: String, to target: String) -> (root: String, trail: [String]) {
        let root: String
        if target == home || target.hasPrefix(home == "/" ? "/" : home + "/") {
            root = home
        } else {
            root = "/"
        }
        guard target != root else { return (root, []) }
        let relative = target.dropFirst(root == "/" ? 1 : root.count + 1)
        var trail: [String] = []
        var current = root
        for component in relative.split(separator: "/") {
            current = join(current, String(component))
            trail.append(current)
        }
        return (root, trail)
    }

    func close() {
        opening?.cancel()
        opening = nil
        if let client {
            Task { await client.close() }
        }
        client = nil
        try? FileManager.default.removeItem(at: downloadsDirectory)
    }

    private func sftp() async throws -> SFTPClient {
        if let client { return client }
        if let opening { return try await opening.value }
        let task = Task { [computers, hostID] in try await computers.openSFTP(hostID: hostID) }
        opening = task
        defer { opening = nil }
        let opened = try await task.value
        client = opened
        return opened
    }

    /// Runs `body` on the session, reopening once if the channel was lost.
    private func withClient<T: Sendable>(_ body: (SFTPClient) async throws -> T) async throws -> T {
        do {
            return try await body(try await sftp())
        } catch SFTPError.connectionLost {
            client = nil
            return try await body(try await sftp())
        }
    }

    // MARK: Listing

    func listing(for path: String) -> Listing? {
        listings[path]
    }

    func load(_ path: String) async {
        loadingPaths.insert(path)
        defer { loadingPaths.remove(path) }
        do {
            let entries = try await withClient { try await $0.listDirectory(path) }
            listings[path] = Listing(entries: Self.sorted(entries), loadedAt: Date())
            listingErrors[path] = nil
        } catch {
            listingErrors[path] = Self.describe(error)
        }
    }

    /// Folders first, then files, each case-insensitively by name.
    nonisolated static func sorted(_ entries: [SFTPEntry]) -> [SFTPEntry] {
        entries.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// Whether a symlink points at a folder.
    func resolvesToDirectory(_ path: String) async -> Bool {
        (try? await withClient { try await $0.stat(path) })?.isDirectory ?? false
    }

    // MARK: Actions

    /// Downloads `remotePath` into this session's scratch folder.
    func download(_ remotePath: String, name: String) async throws -> URL {
        let folder = downloadsDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(Self.localFileName(name))
        transfer = Transfer(kind: .download, name: name, bytes: 0, total: nil)
        defer { transfer = nil }
        try await withClient { client in
            try await client.download(remotePath, to: destination) { [weak self] progress in
                Task { @MainActor in self?.updateTransfer(progress) }
            }
        }
        return destination
    }

    /// Uploads a local file into `directory`, avoiding a name already there.
    func upload(from localURL: URL, preferredName: String, into directory: String) async {
        let name = uniqueName(preferredName, in: directory)
        transfer = Transfer(kind: .upload, name: name, bytes: 0, total: nil)
        defer { transfer = nil }
        do {
            try await withClient { client in
                try await client.upload(from: localURL, to: Self.join(directory, name)) { [weak self] progress in
                    Task { @MainActor in self?.updateTransfer(progress) }
                }
            }
        } catch {
            actionError = Self.describe(error)
        }
        await load(directory)
    }

    func makeFolder(named name: String, in directory: String) async {
        await perform(in: directory) { try await $0.mkdir(Self.join(directory, name)) }
    }

    func rename(_ entry: SFTPEntry, to newName: String, in directory: String) async {
        await perform(in: directory) {
            try await $0.rename(Self.join(directory, entry.name), to: Self.join(directory, newName))
        }
    }

    func delete(_ entry: SFTPEntry, in directory: String) async {
        let path = Self.join(directory, entry.name)
        do {
            if entry.isDirectory {
                try await withClient { try await $0.rmdir(path) }
            } else {
                try await withClient { try await $0.remove(path) }
            }
        } catch SFTPError.failure where entry.isDirectory {
            actionError = L10n.string(
                "mobile.ssh.files.error.folderNotEmpty",
                defaultValue: "This folder isn't empty. Delete what's inside it first."
            )
        } catch {
            actionError = Self.describe(error)
        }
        await load(directory)
    }

    private func perform(in directory: String, _ body: (SFTPClient) async throws -> Void) async {
        do {
            try await withClient(body)
        } catch {
            actionError = Self.describe(error)
        }
        await load(directory)
    }

    private func updateTransfer(_ progress: SFTPTransferProgress) {
        guard var current = transfer else { return }
        current.bytes = progress.bytesTransferred
        current.total = progress.totalBytes ?? current.total
        transfer = current
    }

    private func uniqueName(_ name: String, in directory: String) -> String {
        let taken = Set(listings[directory]?.entries.map(\.name) ?? [])
        guard taken.contains(name) else { return name }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        for index in 2...999 {
            let candidate = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            if !taken.contains(candidate) { return candidate }
        }
        return name
    }

    // MARK: Helpers

    nonisolated static func join(_ directory: String, _ name: String) -> String {
        directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }

    nonisolated static func displayName(of path: String) -> String {
        path == "/" ? "/" : (path as NSString).lastPathComponent
    }

    /// Remote names may contain `/`-free characters iOS still rejects; keep
    /// the local copy's name safe while preserving the extension.
    nonisolated static func localFileName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: ":", with: "_")
        return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "file" : cleaned
    }

    /// A name is usable when it is non-empty and names one path component.
    nonisolated static func isValidName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && trimmed != "." && trimmed != ".." && !trimmed.contains("/")
    }

    static func describe(_ error: any Error) -> String {
        switch error {
        case SFTPError.permissionDenied:
            L10n.string(
                "mobile.ssh.files.error.permissionDenied",
                defaultValue: "You don't have permission to do that on this computer."
            )
        case SFTPError.noSuchFile:
            L10n.string(
                "mobile.ssh.files.error.noSuchFile",
                defaultValue: "That file or folder doesn't exist anymore."
            )
        case SFTPError.connectionLost:
            L10n.string(
                "mobile.ssh.files.error.connectionLost",
                defaultValue: "The connection to this computer was lost. Try again."
            )
        case SFTPError.failure(let message) where !message.isEmpty:
            String(
                format: L10n.string("mobile.ssh.files.error.serverFormat", defaultValue: "The computer reported an error: %@"),
                message
            )
        default:
            L10n.string(
                "mobile.ssh.files.error.generic",
                defaultValue: "Something went wrong talking to this computer. Try again."
            )
        }
    }
}
#endif
