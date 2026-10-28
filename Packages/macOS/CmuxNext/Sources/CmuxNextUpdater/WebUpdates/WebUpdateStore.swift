import CmuxNextCompat
import CmuxNextWakeups
import CryptoKit
public import Foundation

/// The web updates kept on disk (plans/cmux-next/web-ota.md), under the app's Application Support
/// folder:
///
///     web-updates/state.json      which update to serve, the one before it, the newest taken
///     web-updates/trees/<key>/    each unpacked update (WebUpdateTree layout)
///
/// Every method blocks on files; the updater calls them off the main actor.
nonisolated public struct WebUpdateStore: Sendable {
    public let base: URL

    public init(base: URL) {
        self.base = base
    }

    /// `web-updates` in `applicationSupport/<bundle id>`.
    public static func standard(bundleIdentifier: String?) -> WebUpdateStore? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let app = support.appending(path: bundleIdentifier ?? "cmux-next", directoryHint: .isDirectory)
        return WebUpdateStore(base: app.appending(path: "web-updates", directoryHint: .isDirectory))
    }

    var stateFile: URL { base.appending(path: "state.json") }
    var trees: URL { base.appending(path: "trees", directoryHint: .isDirectory) }

    public func tree(for key: String) -> WebUpdateTree {
        WebUpdateTree(root: trees.appending(path: key, directoryHint: .isDirectory))
    }

    public func readState() -> WebUpdateState {
        guard let data = try? Data(contentsOf: stateFile),
              let state = try? JSONDecoder().blockingDecode(WebUpdateState.self, from: data)
        else { return WebUpdateState() }
        return state
    }

    public func write(_ state: WebUpdateState) throws {
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(state).write(to: stateFile, options: .atomic)
    }

    /// The folder of `pointer`'s update when it is on disk and its files still match the signed
    /// digest, else nil.
    public func verifiedTree(_ pointer: WebUpdatePointer) -> URL? {
        let tree = tree(for: pointer.key)
        guard (try? tree.outputDigest()) == pointer.outputs, tree.abi == pointer.abi else { return nil }
        return tree.root
    }

    /// Checks `archive` (downloaded for `pointer`) against the pointer's size and SHA-256, unpacks
    /// it, checks the tree's digest and abi and that it holds every shared file its bundles name
    /// (``WebUpdateTree/missingSharedFiles()``), and keeps it as `trees/<key>`. Returns the folder.
    @concurrent public func install(archive: URL, pointer: WebUpdatePointer) async throws(WebUpdateRefusal) -> URL {
        let (size, digest) = try Self.sizeAndDigest(of: archive)
        guard size == pointer.size, digest == pointer.sha256 else { throw .integrity("archive digest") }
        let staging = base.appending(path: "staging-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: staging) }
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        } catch {
            throw .transfer("no staging folder: \(error.localizedDescription)")
        }
        try await Self.unpack(archive, into: staging)
        let unpacked = WebUpdateTree(root: staging)
        guard try unpacked.outputDigest() == pointer.outputs else { throw .integrity("tree digest") }
        guard unpacked.abi == pointer.abi else { throw .integrity("tree abi") }
        // A page of the update imports React from the update's own pages/_shared (cmux-page://cmux.shared/).
        if let missing = try unpacked.missingSharedFiles().first { throw .integrity("shared \(missing)") }
        let destination = tree(for: pointer.key).root
        do {
            try FileManager.default.createDirectory(at: trees, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.moveItem(at: staging, to: destination)
        } catch {
            throw .transfer("could not keep the update: \(error.localizedDescription)")
        }
        return destination
    }

    /// Removes every kept tree and leftover staging folder but `keys`.
    public func prune(keeping keys: Set<String>) {
        for name in (try? FileManager.checked.contentsOfDirectory(atPath: trees.path)) ?? [] where !keys.contains(name) {
            try? FileManager.checked.removeItem(at: trees.appending(path: name))
        }
        for name in (try? FileManager.checked.contentsOfDirectory(atPath: base.path)) ?? [] where name.hasPrefix("staging-") {
            try? FileManager.checked.removeItem(at: base.appending(path: name))
        }
    }

    static func sizeAndDigest(of file: URL) throws(WebUpdateRefusal) -> (Int, String) {
        guard let handle = try? FileHandle.blockingForReading(from: file) else { throw .integrity("unreadable archive") }
        defer { try? handle.close() }
        var hash = SHA256()
        var size = 0
        while let chunk = try? handle.blockingRead(upToCount: 1 << 20), !chunk.isEmpty {
            size += chunk.count
            guard size <= WebUpdatePointer.maximumSize else { throw .integrity("archive too large") }
            hash.update(data: chunk)
        }
        return (size, WebUpdateTree.hex(hash.finalize()))
    }

    /// `tar -xzf` into `folder`. The archive's digest was checked against the signed pointer first.
    ///
    /// The spawn runs off the caller through ``AsyncProcess``, and tar at the caller's priority's `processQoS`.
    /// A cancel lets tar finish: the caller removes `folder` after this returns, never while tar writes into it.
    /// `onLaunch` gets tar's pid on the thread that spawned it (tests check that thread).
    @concurrent static func unpack(_ archive: URL, into folder: URL,
                                   onLaunch: (@Sendable (Int32) -> Void)? = nil) async throws(WebUpdateRefusal) {
        let request = ProcessRequest(URL(fileURLWithPath: "/usr/bin/tar"),
                                     ["-xzf", archive.path, "-C", folder.path, "--no-same-owner", "--no-same-permissions"],
                                     onCancel: .finish, onLaunch: onLaunch)
        let outcome: ProcessOutcome
        do {
            outcome = try await AsyncProcess().run(request)
        } catch {
            throw .integrity("the archive did not unpack")
        }
        guard outcome.succeeded else { throw .integrity("the archive did not unpack") }
    }
}

/// `web-updates/state.json`.
nonisolated public struct WebUpdateState: Sendable, Equatable, Codable {
    /// The update to serve (nil: the bundled web).
    public var active: WebUpdatePointer?
    /// The update served before ``active``, for a roll back.
    public var previous: WebUpdatePointer?
    /// The newest `committed_at` taken: an older pointer is never taken again, so a replayed old
    /// signed pointer cannot roll the web back, and a rolled-back update is not taken again.
    public var floor: Int

    public init(active: WebUpdatePointer? = nil, previous: WebUpdatePointer? = nil, floor: Int = 0) {
        self.active = active
        self.previous = previous
        self.floor = floor
    }

    /// The keys whose trees must stay on disk.
    public var keptKeys: Set<String> { Set([active?.key, previous?.key].compactMap { $0 }) }
}
