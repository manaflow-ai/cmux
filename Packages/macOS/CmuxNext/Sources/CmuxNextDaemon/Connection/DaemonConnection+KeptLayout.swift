import Foundation

/// One kept tab to restart (the next launch after End Sessions, Keep Layout): a dead terminal
/// tab with the workspace store's `relaunch` record. `restart-tab` gives it a new shell in place,
/// under the same terminal id: the tab id, its slot, name, pin and group stay, and the shell
/// starts in the record's directory (else home), so the pane, its split and ratio never change.
public struct KeptTabRelaunch: Sendable, Equatable {
    public var surface: SurfaceID

    /// The kept tabs of `tree` to restart, in tree order.
    public static func steps(tree: DaemonTree) -> [KeptTabRelaunch] {
        tree.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs)
            .filter { $0.kind == .pty && $0.dead && $0.relaunch != nil }
            .map { KeptTabRelaunch(surface: $0.surface) }
    }
}

/// What `relaunchKeptTabs` did.
public struct KeptTabsRelaunched: Sendable, Equatable {
    public var relaunched: Int
    /// One line per kept tab that failed (it stays dead).
    public var failures: [String]
}

extension DaemonConnection {
    /// Restarts a shell in every kept tab, all at once: each `restart-tab` answers when its
    /// worker started, so the tree reports every kept tab restarting together, in its own slot,
    /// and each pane maps its restored tabs once, not once per create, move and close in turn
    /// (cx-8w027.23). A tab that fails stays dead and is reported; the rest continue.
    @discardableResult
    public func relaunchKeptTabs() async throws -> KeptTabsRelaunched {
        let steps = KeptTabRelaunch.steps(tree: try await listWorkspaces())
        let failures = await withTaskGroup(of: String?.self) { group in
            for step in steps {
                group.addTask {
                    do {
                        _ = try await self.request(RestartTabRequest(surface: step.surface))
                        return nil
                    } catch {
                        return "surface \(step.surface.rawValue): \(error)"
                    }
                }
            }
            var failures: [String] = []
            for await failure in group { if let failure { failures.append(failure) } }
            return failures
        }
        return KeptTabsRelaunched(relaunched: steps.count - failures.count, failures: failures)
    }
}
