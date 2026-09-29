import CmuxCloud
import Foundation

/// One WorkspaceRequest round trip to a Cloud machine's daemon. Throws
/// ``CloudWorkspaceFileRPCUnavailable`` when no direct channel can be made, so the
/// caller may fall back to the exec API; any other error is the daemon's answer.
protocol CloudWorkspaceFileRPC: Sendable {
    nonisolated func request(vmID: String, _ requestJSON: Data) async throws -> Data
}

/// The direct daemon channel cannot be used (old bundled client, no private route,
/// carrier start failure or a closed channel).
struct CloudWorkspaceFileRPCUnavailable: Error {}

/// Uses the machine's persistent `remote rpc --stream` carrier, with the originating
/// workspace, account and team re-validated around every request.
struct LiveCloudWorkspaceFileRPC: CloudWorkspaceFileRPC {
    let target: CloudFileExplorerTarget?

    nonisolated func request(vmID: String, _ requestJSON: Data) async throws -> Data {
        guard let target else { throw FileExplorerError.providerUnavailable }
        try await target.validate(vmID: vmID)
        let links = await MainActor.run { CmuxTuiSurfaceProviderRegistry.shared.links }
        let rpc: CloudWorkspaceRPCProcess
        do {
            guard await links.supportsWorkspaceRPC() else { throw CloudWorkspaceFileRPCUnavailable() }
            rpc = try await links.workspaceRPC(machineID: vmID)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CloudWorkspaceFileRPCUnavailable()
        }
        let data: Data
        do {
            data = try await rpc.request(requestJSON)
        } catch is CloudMachineLink.LinkError {
            throw CloudWorkspaceFileRPCUnavailable()
        }
        try Task.checkCancellation()
        try await target.validate(vmID: vmID)
        return data
    }
}

/// Filesystem operations over the daemon's workspace service. The machine's root
/// directory is opened once as the workspace, so every absolute path maps to a
/// workspace-relative one; the daemon resolves paths under that pinned root.
actor CloudDaemonFileExplorer {
    private static let maxDirectoryEntries = 10_000
    private static let directoryPageLimit = 4_096
    private let rpc: any CloudWorkspaceFileRPC
    private var workspaceID: String?

    init(rpc: any CloudWorkspaceFileRPC) {
        self.rpc = rpc
    }

    /// Lists one directory. Symlinks are resolved with `stat` so a link to a
    /// directory expands like the exec path's `is_dir(follow_symlinks=True)`.
    func listDirectory(vmID: String, path: String, showHidden: Bool) async throws -> [FileExplorerEntry] {
        let parent = Self.normalizedDirectory(path)
        var cursor: Any?
        var raw: [[String: Any]] = []
        repeat {
            var request: [String: Any] = [
                "type": "list-directory", "path": Self.relative(parent),
                "include_hidden": showHidden, "limit": Self.directoryPageLimit,
            ]
            if let cursor { request["cursor"] = cursor }
            let response = try await workspaceRequest(vmID: vmID, request)
            guard response["type"] as? String == "directory",
                  let entries = response["entries"] as? [[String: Any]] else {
                throw FileExplorerError.remoteCommandFailed("")
            }
            raw += entries
            if raw.count > Self.maxDirectoryEntries { throw FileExplorerError.remoteCommandFailed("") }
            cursor = response["next_cursor"]
            if cursor is NSNull { cursor = nil }
        } while cursor != nil

        var entries: [FileExplorerEntry] = []
        var symlinks: [(index: Int, path: String)] = []
        for item in raw {
            guard let name = item["name"] as? String, let kind = item["kind"] as? String else { continue }
            if !showHidden, name.hasPrefix(".") { continue }
            let entryPath = parent == "/" ? "/" + name : parent + "/" + name
            if kind == "symlink" { symlinks.append((entries.count, entryPath)) }
            entries.append(FileExplorerEntry(name: name, path: entryPath, isDirectory: kind == "directory"))
        }
        guard !symlinks.isEmpty else { return entries }
        let resolved = try await withThrowingTaskGroup(of: (Int, Bool).self) { group in
            for link in symlinks {
                group.addTask { (link.index, await self.isDirectoryFollowingLinks(vmID: vmID, path: link.path)) }
            }
            var result: [Int: Bool] = [:]
            for try await (index, isDirectory) in group { result[index] = isDirectory }
            return result
        }
        for (index, isDirectory) in resolved where isDirectory {
            let entry = entries[index]
            entries[index] = FileExplorerEntry(name: entry.name, path: entry.path, isDirectory: true)
        }
        return entries
    }

    /// Reads a whole regular file up to `limit` bytes in one request.
    func readFile(vmID: String, path: String, limit: Int) async throws -> Data {
        let response = try await workspaceRequest(vmID: vmID, [
            "type": "read-file", "path": Self.relative(path), "offset": 0, "limit": limit + 1,
        ])
        guard response["type"] as? String == "file",
              let encoded = response["data"] as? String,
              let data = Data(base64Encoded: encoded) else {
            throw FileExplorerError.remoteCommandFailed("")
        }
        if data.count > limit || response["eof"] as? Bool == false {
            throw FileExplorerError.remoteFileTooLarge
        }
        return data
    }

    private func isDirectoryFollowingLinks(vmID: String, path: String) async -> Bool {
        let response = try? await workspaceRequest(vmID: vmID, [
            "type": "stat", "path": Self.relative(path), "follow_symlinks": true,
        ])
        let stat = response?["stat"] as? [String: Any]
        return stat?["kind"] as? String == "directory"
    }

    /// Sends a request that needs the workspace id, opening the root workspace on
    /// first use and once more if the channel was replaced (ids are per connection).
    private func workspaceRequest(vmID: String, _ body: [String: Any]) async throws -> [String: Any] {
        for attempt in 0..<2 {
            let workspace = try await openedWorkspace(vmID: vmID)
            var request = body
            request["workspace"] = workspace
            do {
                return try await send(vmID: vmID, request)
            } catch let error as CloudWorkspaceRPCProcess.RemoteError where attempt == 0 && Self.isStaleWorkspace(error) {
                if workspaceID == workspace { workspaceID = nil }
            }
        }
        throw FileExplorerError.remoteCommandFailed("")
    }

    private func openedWorkspace(vmID: String) async throws -> String {
        if let workspaceID { return workspaceID }
        let response = try await send(vmID: vmID, ["type": "open-workspace", "root": "/"])
        guard response["type"] as? String == "workspace", let id = response["id"] as? String else {
            throw FileExplorerError.remoteCommandFailed("")
        }
        workspaceID = id
        return id
    }

    private func send(vmID: String, _ request: [String: Any]) async throws -> [String: Any] {
        let body = try JSONSerialization.data(withJSONObject: request)
        let data: Data
        do {
            data = try await rpc.request(vmID: vmID, body)
        } catch let error as CloudWorkspaceFileRPCUnavailable {
            // A new channel leases new workspace ids.
            workspaceID = nil
            throw error
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FileExplorerError.remoteCommandFailed("")
        }
        return object
    }

    private static func isStaleWorkspace(_ error: CloudWorkspaceRPCProcess.RemoteError) -> Bool {
        error.code == "unknown-workspace" || error.code == "workspace-not-found"
    }

    private static func normalizedDirectory(_ path: String) -> String {
        var path = path.isEmpty ? "/" : path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// Workspace-relative form of an absolute path under the `/` root.
    private static func relative(_ path: String) -> String {
        String(path.drop(while: { $0 == "/" }))
    }
}
