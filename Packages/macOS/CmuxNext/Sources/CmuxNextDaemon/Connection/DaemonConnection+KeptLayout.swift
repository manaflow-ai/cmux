import Foundation

/// One kept tab to restart (the next launch after End Sessions, Keep Layout): a dead terminal
/// tab with the workspace store's `relaunch` record. `restart-tab` gives it a new shell in place,
/// under the same terminal id: the tab id, its slot, name, pin and group stay, and the shell
/// starts in the record's directory (else home), so the pane, its split and ratio never change.
public struct KeptTabRelaunch: Sendable, Equatable {
    public var surface: SurfaceID

    /// The kept tabs of `tree` to restart on connect, in tree order. Parked
    /// ones and ones in a protected folder (``TabRelaunch/startsOnShow(home:)``) wait until
    /// their workspace is first shown.
    public static func steps(tree: DaemonTree, home: String? = nil) -> [KeptTabRelaunch] {
        tree.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs)
            .filter { $0.kind == .pty && $0.dead && $0.relaunch.map { !$0.startsOnShow(home: home) } == true }
            .map { KeptTabRelaunch(surface: $0.surface) }
    }
}

/// What `relaunchKeptTabs` did.
public struct KeptTabsRelaunched: Sendable, Equatable {
    public var relaunched: Int
    /// One line per kept tab that failed (it stays dead).
    public var failures: [String]
    /// The kept tabs that failed.
    public var failedSurfaces: Set<SurfaceID> = []
}

extension DaemonConnection {
    /// The kept-tab restarts `relaunchKeptTabs` keeps in flight.
    static let keptTabRestartsInFlight = 8

    /// Restarts a shell in every kept tab, in parallel (up to `keptTabRestartsInFlight`): each
    /// `restart-tab` answers when its worker started, so the kept tabs restart together, each in its own slot,
    /// and each pane maps its restored tabs once, not once per create, move and close in turn
    /// (cx-8w027.23). A tab that fails stays dead and is reported; the rest continue.
    @discardableResult
    public func relaunchKeptTabs() async throws -> KeptTabsRelaunched {
        let steps = KeptTabRelaunch.steps(tree: try await listWorkspaces())
        let failures = await withTaskGroup(of: (SurfaceID, String)?.self) { group in
            // At most `keptTabRestartsInFlight` at once: each restart starts a host and a shell.
            var pending = steps.makeIterator()
            for step in steps.prefix(Self.keptTabRestartsInFlight) {
                _ = pending.next()
                group.addTask { await self.restart(step) }
            }
            var failures: [(SurfaceID, String)] = []
            for await failure in group {
                if let failure { failures.append(failure) }
                if let step = pending.next() { group.addTask { await self.restart(step) } }
            }
            return failures
        }
        return KeptTabsRelaunched(relaunched: steps.count - failures.count, failures: failures.map(\.1),
                                  failedSurfaces: Set(failures.map(\.0)))
    }

    /// One kept tab's `restart-tab`: nil when the daemon took it, else the tab and the failure line.
    private func restart(_ step: KeptTabRelaunch) async -> (SurfaceID, String)? {
        do {
            _ = try await request(RestartTabRequest(surface: step.surface))
            return nil
        } catch {
            return (step.surface, "surface \(step.surface.rawValue): \(error)")
        }
    }
}
