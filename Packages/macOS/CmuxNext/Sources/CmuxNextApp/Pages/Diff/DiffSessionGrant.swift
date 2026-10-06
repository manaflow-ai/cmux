import Darwin
import Foundation
import Synchronization

/// What one diff tab may do in the sidecar's session root, as the files the
/// sidecar checks (the classic CLI wrote the same ones, CLI/cmux_open.swift
/// before 90b48fa188d):
/// - `.branch-session-<group>.json` `{token, groupID, allowedRepoRoots}`: the
///   token may open sessions for exactly this repository;
/// - `.manifest-<token>.json`: the files the token may read. The sidecar adds
///   each session's patch; it never creates a manifest, so this one starts with
///   a placeholder entry;
/// - `.session-lease-<token>.lock`, held (flock) while the tab lives, so the
///   sidecar's orphan sweep never removes a live tab's patches.
///
/// The token is 48 random hex characters and never leaves the tab: the tab's
/// provider stamps it on every request and its patch source serves only it.
nonisolated final class DiffSessionGrant: Sendable {
    let root: URL
    let token: String
    let group: String
    let repository: String
    private let lease = Mutex<Int32>(-1)

    static let placeholderPath = "/viewer.html"

    private init(root: URL, token: String, group: String, repository: String, lease: Int32) {
        self.root = root
        self.token = token
        self.group = group
        self.repository = repository
        self.lease.withLock { $0 = lease }
    }

    /// Takes the lease, then writes the grant files (0600). Blocking file IO:
    /// call it off the main actor.
    static func create(root: URL, repository: String) throws -> DiffSessionGrant {
        let token = randomHex(bytes: 24)
        let group = "tab-" + randomHex(bytes: 8)
        let lease = Darwin.open(root.appending(path: ".session-lease-\(token).lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard lease >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        guard flock(lease, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(lease)
            throw CocoaError(.fileLocking)
        }
        let grant = DiffSessionGrant(root: root, token: token, group: group, repository: repository, lease: lease)
        do {
            let placeholder = root.appending(path: ".viewer-\(token).html")
            try write(Data("<!doctype html>\n".utf8), to: placeholder)
            let manifest: [String: Any] = [
                "token": token,
                "files": [["request_path": placeholderPath, "file_path": placeholder.path, "mime_type": "text/html",
                           "remote_url": NSNull()]],
            ]
            try write(JSONSerialization.data(withJSONObject: manifest), to: grant.manifestURL)
            let session: [String: Any] = ["token": token, "groupID": group, "allowedRepoRoots": [repository]]
            try write(JSONSerialization.data(withJSONObject: session), to: root.appending(path: ".branch-session-\(group).json"))
        } catch {
            grant.remove()
            throw error
        }
        return grant
    }

    var manifestURL: URL { root.appending(path: ".manifest-\(token).json") }

    /// Removes the grant files, the patches its manifest lists inside the root,
    /// then releases the lease. Idempotent; blocking file IO.
    func remove() {
        let lease = self.lease.withLock { lease -> Int32 in
            defer { lease = -1 }
            return lease
        }
        guard lease >= 0 else { return }
        let resolver = DiffPatchResolver(root: root, token: token)
        for file in resolver.listedFiles() { try? FileManager.default.removeItem(at: file) }
        for name in [".branch-session-\(group).json", ".manifest-\(token).json", ".manifest-\(token).lock",
                     ".viewer-\(token).html", ".session-lease-\(token).lock"] {
            try? FileManager.default.removeItem(at: root.appending(path: name))
        }
        Darwin.close(lease)
    }

    private static func write(_ data: Data, to url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    static func randomHex(bytes count: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<count).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }.joined()
    }
}

/// The per-user session root every diff tab shares: `<user temp>/cmux-next-diff`,
/// a 0700 directory this user owns (the sidecar refuses anything else).
nonisolated enum DiffSessionRoot {
    static func url(temporary: URL = FileManager.default.temporaryDirectory) -> URL {
        temporary.appending(path: "cmux-next-diff", directoryHint: .isDirectory)
    }

    /// Creates the root (or checks it is a real directory of this user) and sets
    /// 0700. Blocking file IO.
    static func prepare(_ root: URL) throws -> URL {
        if mkdir(root.path, 0o700) != 0, errno != EEXIST { throw CocoaError(.fileWriteNoPermission) }
        var info = stat()
        guard lstat(root.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else {
            throw CocoaError(.fileWriteNoPermission)
        }
        guard chmod(root.path, 0o700) == 0 else { throw CocoaError(.fileWriteNoPermission) }
        return root
    }

    /// Removes the grants of tabs that are gone (a crash, a quit before cleanup):
    /// a branch session whose token's lease nobody holds. Leases are taken
    /// before a grant's files exist, so a grant being created is never removed.
    static func sweep(_ root: URL) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return }
        for name in names where name.hasPrefix(".branch-session-") && name.hasSuffix(".json") {
            let url = root.appending(path: name)
            // concurrency-allow: nonisolated sweep; DiffPageRuntime runs it from a @concurrent task
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count < 64 * 1024,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let token = object["token"] as? String, DiffPatchResolver.isValidToken(token),
                  !leaseIsHeld(root: root, token: token) else { continue }
            let resolver = DiffPatchResolver(root: root, token: token)
            for file in resolver.listedFiles() { try? FileManager.default.removeItem(at: file) }
            for stale in [name, ".manifest-\(token).json", ".manifest-\(token).lock", ".viewer-\(token).html",
                          ".session-lease-\(token).lock"] {
                try? FileManager.default.removeItem(at: root.appending(path: stale))
            }
        }
    }

    static func leaseIsHeld(root: URL, token: String) -> Bool {
        let descriptor = Darwin.open(root.appending(path: ".session-lease-\(token).lock").path, O_RDWR | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
            flock(descriptor, LOCK_UN)
            return false
        }
        return errno == EWOULDBLOCK
    }
}
