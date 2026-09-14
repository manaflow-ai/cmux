import Foundation

/// Resolves exact views, keeping terminal process identity separate from tab
/// placement identity. A terminal-wide resolver may choose a different tab's
/// numeric surface when that terminal is projected into multiple workspaces.
struct CloudTerminalViewResolver: Sendable {
    let commandRunner: any CloudTuiCommandRunning
    let socketPath: String

    #if compiler(>=6.2)
    @concurrent
    #else
    @Sendable
    #endif
    nonisolated func resolve(terminalByTab: [String: String]) async -> [String: CloudTuiSurfaceIDResolution] {
        guard !terminalByTab.isEmpty else { return [:] }
        do {
            let snapshot = try await commandRunner.runTuiCommand(
                arguments: CloudTuiCommandLine.snapshotArguments(socketPath: socketPath), deadline: .seconds(15)
            )
            guard let object = try? JSONSerialization.jsonObject(with: snapshot) as? [String: Any],
                  CmuxTuiSnapshotParser.authoritativeGraphIsValid(object) else {
                return terminalByTab.mapValues { _ in .retryable("invalid view snapshot", failure: .invalidResponse) }
            }
            let terminals = Dictionary(uniqueKeysWithValues: (object["terminals"] as? [[String: Any]] ?? []).compactMap {
                terminal -> (String, String)? in
                guard let id = terminal["id"] as? String else { return nil }
                return (id, terminal["lifecycle"] as? String ?? "running")
            })
            let tabs = Dictionary(uniqueKeysWithValues: (object["tabs"] as? [[String: Any]] ?? []).compactMap {
                tab -> (String, String)? in
                guard tab["content_kind"] as? String == "terminal",
                      let id = tab["id"] as? String, let terminal = tab["content_id"] as? String else { return nil }
                return (id, terminal)
            })
            var results: [String: CloudTuiSurfaceIDResolution] = [:]
            var live: [String: String] = [:]
            for (tabID, terminalID) in terminalByTab {
                if terminals[terminalID] == nil || ["exited", "tombstoned"].contains(terminals[terminalID]) {
                    results[tabID] = .exited
                } else if tabs[tabID] == terminalID {
                    live[tabID] = terminalID
                } else {
                    results[tabID] = .retryable("the requested tab is no longer present", failure: .notReady)
                }
            }
            guard !live.isEmpty else { return results }
            let tree = try await commandRunner.runTuiCommand(
                arguments: CloudTuiCommandLine.legacyListWorkspacesArguments(socketPath: socketPath), deadline: .seconds(15)
            )
            let surfaces = CloudTuiLegacySnapshotParser().viewSurfaceIDs(from: tree, terminalByTab: live)
            for tabID in live.keys {
                results[tabID] = surfaces[tabID].map(CloudTuiSurfaceIDResolution.resolved)
                    ?? .retryable("the requested tab changed during resolution", failure: .notReady)
            }
            return results
        } catch {
            let answer = CloudTuiDaemonAnswer(error: error)
            return terminalByTab.mapValues { _ in .retryable(answer.reason, failure: answer.attachmentFailure) }
        }
    }
}
