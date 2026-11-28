import CmuxNextCompat
import CryptoKit
public import Foundation

/// The web updates kept on disk (plans/cmux-next/web-ota.md), under the app's Application Support
/// folder:
///
///     web-updates/state.json      which update to serve, the one before it, the newest taken
///     web-updates/trees.noindex/<key>/    each unpacked update (WebUpdateTree layout)
///
/// The trees live under a folder whose name ends in `.noindex`, so Spotlight skips them, as it skips
/// `~/.cmux/worktrees.noindex` (cmux-git `worktree_root.rs`). Each update unpacks about 2,250 files
/// (52 MB), and on a Mac taking every merge a new tree came every few minutes; Spotlight's workers
/// were reading those trees' `index.html` and `.js` files on a Mac at load 105 on 15 cores
/// (2026-11-27). Spotlight on macOS 27 ignores `.metadata_never_index`; the suffix is what works.
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
        let store = WebUpdateStore(base: app.appending(path: "web-updates", directoryHint: .isDirectory))
        store.moveLegacyTrees()
        return store
    }

    var stateFile: URL { base.appending(path: "state.json") }
    var trees: URL { base.appending(path: "trees.noindex", directoryHint: .isDirectory) }
    var legacyTrees: URL { base.appending(path: "trees", directoryHint: .isDirectory) }

    /// Moves the trees an older build kept in `trees/` to `trees.noindex/`: one rename on the same
    /// volume, so the kept updates (and their keys in state.json) stay usable without a download.
    /// Left alone when `trees.noindex/` already exists; `prune` removes a leftover `trees/` then.
    func moveLegacyTrees() {
        let manager = FileManager.default
        guard manager.fileExists(atPath: legacyTrees.path), !manager.fileExists(atPath: trees.path) else { return }
        try? manager.moveItem(at: legacyTrees, to: trees)
    }

    public func tree(for key: String) -> WebUpdateTree {
        WebUpdateTree(root: trees.appending(path: key, directoryHint: .isDirectory))
    }

    public func readState() -> WebUpdateState {
        guard let data = try? Data(contentsOf: stateFile),
              let state = try? JSONDecoder().decode(WebUpdateState.self, from: data)
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
    /// it, checks the tree's digest and abi, and keeps it as `trees.noindex/<key>`. Returns the folder.
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
        return try keep(staging, pointer: pointer)
    }

    /// A fresh staging folder (not created) and a chunk store beside it, for one `cas/1` fetch
    /// (``WebUpdater/CasFetch``). Both are `staging-*`, so ``prune(keeping:)`` removes leftovers.
    public func casStaging() -> (tree: URL, chunks: URL) {
        let id = UUID().uuidString
        return (base.appending(path: "staging-\(id)", directoryHint: .isDirectory),
                base.appending(path: "staging-\(id)-chunks", directoryHint: .isDirectory))
    }

    /// Checks `staged` (a tree `cas/1` assembled for `pointer`) against the pointer's tree digest
    /// and abi, the same checks an unpacked archive passes, and keeps it as `trees/<key>`.
    @concurrent public func install(tree staged: URL, pointer: WebUpdatePointer) async throws(WebUpdateRefusal) -> URL {
        let kept = Result { () throws(WebUpdateRefusal) -> URL in try keep(staged, pointer: pointer) }
        if case .failure = kept { try? FileManager.checked.removeItem(at: staged) }
        return try kept.get()
    }

    /// Moves the checked `staging` tree to `trees/<key>`.
    func keep(_ staging: URL, pointer: WebUpdatePointer) throws(WebUpdateRefusal) -> URL {
        let unpacked = WebUpdateTree(root: staging)
        guard try unpacked.outputDigest() == pointer.outputs else { throw .integrity("tree digest") }
        guard unpacked.abi == pointer.abi else { throw .integrity("tree abi") }
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
        let manager = FileManager.default
        for name in (try? manager.contentsOfDirectory(atPath: trees.path)) ?? [] where !keys.contains(name) {
            try? manager.removeItem(at: trees.appending(path: name))
        }
        for name in (try? manager.contentsOfDirectory(atPath: base.path)) ?? [] where name.hasPrefix("staging-") {
            try? manager.removeItem(at: base.appending(path: name))
        }
        // An older build's `trees/` that moveLegacyTrees could not move (trees.noindex/ was already
        // there): nothing serves from it, since tree(for:) reads only trees.noindex/.
        if manager.fileExists(atPath: trees.path), manager.fileExists(atPath: legacyTrees.path) {
            try? manager.removeItem(at: legacyTrees)
        }
    }

    static func sizeAndDigest(of file: URL) throws(WebUpdateRefusal) -> (Int, String) {
        guard let handle = try? FileHandle(forReadingFrom: file) else { throw .integrity("unreadable archive") }
        defer { try? handle.close() }
        var hash = SHA256()
        var size = 0
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            size += chunk.count
            guard size <= WebUpdatePointer.maximumSize else { throw .integrity("archive too large") }
            hash.update(data: chunk)
        }
        return (size, WebUpdateTree.hex(hash.finalize()))
    }

    /// `tar -xzf` into `folder`. The archive's digest was checked against the signed pointer first.
    @concurrent static func unpack(_ archive: URL, into folder: URL) async throws(WebUpdateRefusal) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xzf", archive.path, "-C", folder.path, "--no-same-owner", "--no-same-permissions"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let status: Int32? = await withCheckedContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: nil)
            }
        }
        guard status == 0 else { throw .integrity("the archive did not unpack") }
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
