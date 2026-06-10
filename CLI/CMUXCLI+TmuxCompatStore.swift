import Foundation
import CMUXAgentLaunch
import CmuxFoundation
import CmuxSocketControl
import CoreFoundation
import CryptoKit
import Darwin
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
#if canImport(Security)
import Security
#endif
#if canImport(Sentry)
import Sentry
#endif


// MARK: - tmux compat state store
extension CMUXCLI {
    struct MainVerticalState: Codable {
        /// The surface ID of the "main" (leader) pane on the left side.
        var mainSurfaceId: String
        /// The surface ID of the bottom-most pane in the right column.
        /// Subsequent teammate splits target this pane with direction "down".
        var lastColumnSurfaceId: String?
    }

    struct TmuxCompatStore: Codable {
        var buffers: [String: String] = [:]
        var hooks: [String: String] = [:]
        /// Tracks main-vertical layout state per workspace, keyed by workspace ID.
        var mainVerticalLayouts: [String: MainVerticalState] = [:]
        /// Tracks the last surface created by split-window per workspace.
        /// Used to seed lastColumnSurfaceId when select-layout main-vertical
        /// is called after the first split.
        var lastSplitSurface: [String: String] = [:]

        /// Custom decoder so older store files missing newer keys
        /// (mainVerticalLayouts, lastSplitSurface) decode gracefully
        /// instead of throwing and resetting the entire store.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            buffers = try container.decodeIfPresent([String: String].self, forKey: .buffers) ?? [:]
            hooks = try container.decodeIfPresent([String: String].self, forKey: .hooks) ?? [:]
            mainVerticalLayouts = try container.decodeIfPresent([String: MainVerticalState].self, forKey: .mainVerticalLayouts) ?? [:]
            lastSplitSurface = try container.decodeIfPresent([String: String].self, forKey: .lastSplitSurface) ?? [:]
        }

        init() {}
    }

    private func tmuxCompatStoreURL() -> URL {
        let homePath = ProcessInfo.processInfo.environment["HOME"]
            ?? NSString(string: "~").expandingTildeInPath
        return URL(fileURLWithPath: homePath)
            .appendingPathComponent(".cmuxterm")
            .appendingPathComponent("tmux-compat-store.json")
    }

    func loadTmuxCompatStore() -> TmuxCompatStore {
        let url = tmuxCompatStoreURL()
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(TmuxCompatStore.self, from: data) else {
            return TmuxCompatStore()
        }
        return decoded
    }

    func saveTmuxCompatStore(_ store: TmuxCompatStore) throws {
        let url = tmuxCompatStoreURL()
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: nil)
        let data = try JSONEncoder().encode(store)
        try data.write(to: url, options: .atomic)
    }

    func tmuxPruneCompatWorkspaceState(workspaceId: String) throws {
        var store = loadTmuxCompatStore()
        let removedLayout = store.mainVerticalLayouts.removeValue(forKey: workspaceId) != nil
        let removedSplit = store.lastSplitSurface.removeValue(forKey: workspaceId) != nil
        if removedLayout || removedSplit {
            try saveTmuxCompatStore(store)
        }
    }

    private func tmuxCompatPaneAnchorSurfaceId(_ pane: [String: Any]) -> String? {
        if let selected = pane["selected_surface_id"] as? String, !selected.isEmpty {
            return selected
        }
        let surfaceIds = pane["surface_ids"] as? [String] ?? []
        return surfaceIds.first
    }

    private func tmuxCompatPanePixelFrame(_ pane: [String: Any]) -> (x: Double, y: Double)? {
        guard let frame = pane["pixel_frame"] as? [String: Any],
              let x = doubleFromAny(frame["x"]),
              let y = doubleFromAny(frame["y"]) else {
            return nil
        }
        return (x, y)
    }

    private func tmuxReplacementColumnSurfaceId(
        workspaceId: String,
        layout: MainVerticalState,
        client: SocketClient
    ) -> String? {
        guard let payload = try? client.sendV2(method: "pane.list", params: ["workspace_id": workspaceId]) else {
            return nil
        }
        let panes = payload["panes"] as? [[String: Any]] ?? []
        guard !panes.isEmpty else { return nil }

        guard let mainPane = panes.first(where: { pane in
            let surfaceIds = pane["surface_ids"] as? [String] ?? []
            if surfaceIds.contains(layout.mainSurfaceId) {
                return true
            }
            return (pane["selected_surface_id"] as? String) == layout.mainSurfaceId
        }) else {
            return nil
        }

        let mainPaneId = mainPane["id"] as? String
        let nonMainPanes = panes.filter { ($0["id"] as? String) != mainPaneId }
        guard !nonMainPanes.isEmpty else { return nil }

        let candidatePanes: [[String: Any]]
        if let mainFrame = tmuxCompatPanePixelFrame(mainPane) {
            let rightColumn = nonMainPanes.filter { pane in
                guard let frame = tmuxCompatPanePixelFrame(pane) else { return false }
                return frame.x > mainFrame.x + 0.5
            }
            candidatePanes = rightColumn.isEmpty ? nonMainPanes : rightColumn
        } else {
            candidatePanes = nonMainPanes
        }

        let bottomMostPane = candidatePanes.max { lhs, rhs in
            let lhsFrame = tmuxCompatPanePixelFrame(lhs)
            let rhsFrame = tmuxCompatPanePixelFrame(rhs)
            switch (lhsFrame, rhsFrame) {
            case let (.some(lhsFrame), .some(rhsFrame)):
                if lhsFrame.y == rhsFrame.y {
                    return lhsFrame.x < rhsFrame.x
                }
                return lhsFrame.y < rhsFrame.y
            case (.none, .some):
                return true
            case (.some, .none):
                return false
            case (.none, .none):
                return false
            }
        }

        return bottomMostPane.flatMap { tmuxCompatPaneAnchorSurfaceId($0) }
    }

    func tmuxPruneCompatSurfaceState(
        workspaceId: String,
        surfaceId: String,
        client: SocketClient
    ) throws {
        var store = loadTmuxCompatStore()
        var changed = false

        if store.lastSplitSurface[workspaceId] == surfaceId {
            store.lastSplitSurface.removeValue(forKey: workspaceId)
            changed = true
        }

        if let layout = store.mainVerticalLayouts[workspaceId] {
            if layout.mainSurfaceId == surfaceId {
                store.mainVerticalLayouts.removeValue(forKey: workspaceId)
                store.lastSplitSurface.removeValue(forKey: workspaceId)
                changed = true
            } else if layout.lastColumnSurfaceId == surfaceId {
                var updatedLayout = layout
                let replacementSurfaceId = tmuxReplacementColumnSurfaceId(
                    workspaceId: workspaceId,
                    layout: layout,
                    client: client
                )
                updatedLayout.lastColumnSurfaceId = replacementSurfaceId
                store.mainVerticalLayouts[workspaceId] = updatedLayout
                if let replacementSurfaceId {
                    store.lastSplitSurface[workspaceId] = replacementSurfaceId
                } else {
                    store.lastSplitSurface.removeValue(forKey: workspaceId)
                }
                changed = true
            }
        }

        if changed {
            try saveTmuxCompatStore(store)
        }
    }

    func runShellCommand(_ command: String, stdinText: String) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        if let data = stdinText.data(using: .utf8) {
            stdinPipe.fileHandleForWriting.write(data)
        }
        stdinPipe.fileHandleForWriting.closeFile()
        process.waitUntilExit()

        let stdoutData = ProcessPipeReader.readDataToEndOfFileOrEmpty(from: stdoutPipe.fileHandleForReading)
        let stderrData = ProcessPipeReader.readDataToEndOfFileOrEmpty(from: stderrPipe.fileHandleForReading)
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        return (process.terminationStatus, stdout, stderr)
    }

    func tmuxWaitForSignalURL(name: String) -> URL {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let sanitized = name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        return URL(fileURLWithPath: "/tmp/cmux-wait-for-\(String(sanitized)).sig")
    }

}
