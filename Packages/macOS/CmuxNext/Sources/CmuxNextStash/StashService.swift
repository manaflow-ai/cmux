import CmuxNextCompat
public import CmuxNextDaemon
import CmuxNextDaemonService
import Foundation

/// Stash (a native OneTab, `stash-v1`) on this Mac's daemon: Save and Close, its Undo, and the
/// Stashed Tabs page's restore and delete (the page reads `stash.list` and imports through the
/// daemon itself, and hears `stash-changed`). Restore runs here because only the app knows the pane
/// a page reopens in and shows what came back.
public final class StashService {
    private weak var host: (any StashHost)?

    /// Creates the service over `host`'s daemon.
    /// - Parameter host: The App's side of Stash; held weakly.
    public init(host: any StashHost) {
        self.host = host
    }

    /// Whether `daemon` keeps stashes; without it no stash UI shows. Only this Mac's daemon.
    func serves(_ daemon: DaemonService) -> Bool { daemon.isLocal && daemon.supports(DaemonCapability.stash.rawValue) }

    /// The reason Save and Close of tabs (`workspaces` false) or of whole workspaces is unavailable,
    /// or nil while this Mac's daemon keeps them (`stash-v1`, `stash-workspaces-v1`).
    public func unavailableReason(workspaces: Bool = false) -> String? {
        guard let daemon = host?.localDaemon else { return RefusalStrings.daemonConnecting }
        let capability = workspaces ? DaemonCapability.stashWorkspaces.rawValue : DaemonCapability.stash.rawValue
        guard daemon.isLocal, daemon.supports(DaemonCapability.stash.rawValue), daemon.supports(capability) else {
            return daemon.missingCapabilityMessage(capability)
        }
        return nil
    }

    /// The browser engine imported pages reopen in (`browser.defaultEngine`, WebKit without Chromium).
    public var importEngine: String { host?.stashImportEngine ?? "webkit" }

    /// Closes browser pages `tabs` (this Mac's) into one stash named after the first one's
    /// workspace. Returns the stash's id.
    public func stash(tabs: [ResourceID]) async throws -> String {
        do { return try await state().stashTabs(tabs).stashID } catch { throw Self.failure(error) }
    }

    /// Closes workspaces `workspaces` (this Mac's) whole, every tab and its terminal, into one
    /// stash named `name` (else the workspace's name for one). Returns the stash's id.
    public func stash(workspaces: [ResourceID], name: String?) async throws -> String {
        do {
            if let reason = unavailableReason(workspaces: true) { throw ActionFailure(message: reason) }
            return try await state().stashWorkspaces(workspaces, name: name).stashID
        } catch { throw Self.failure(error) }
    }

    /// Brings every member of stash `id` back where it was (a Save and Close's Undo) and shows
    /// it: whole workspaces as workspaces, pages in their panes.
    public func restoreAll(_ id: String, workspaces: Bool) async throws {
        try await restore(id, members: nil, inNewWorkspace: false, showAsWorkspace: workspaces)
    }

    /// Reopens `members` of stash `id` (every member for nil), where they were or in one new
    /// workspace, and shows them. `here` puts a page whose pane is gone in the active window's
    /// focused pane.
    public func restore(_ id: String, members: [String]?, inNewWorkspace: Bool, showAsWorkspace: Bool? = nil) async throws {
        do {
            let reopened = try await state().restoreStash(id, members: members, target: inNewWorkspace ? .newWorkspace : .here,
                                                          pane: host?.stashRestorePane)
            guard let host, let connection = host.localDaemon.connection else { return }
            await host.localDaemon.appliedThroughReply(on: connection, after: "restore stash")
            host.showRestored(reopened, asWorkspace: showAsWorkspace ?? inNewWorkspace)
        } catch { throw Self.failure(error) }
    }

    /// Deletes `members` of stash `id` (the whole stash for nil) for good.
    public func delete(_ id: String, members: [String]?) async throws {
        do { try await state().deleteStash(id, members: members) } catch { throw Self.failure(error) }
    }

    /// This Mac's daemon's state client, when it keeps stashes.
    private func state() throws -> StateResourceClient {
        guard let daemon = host?.localDaemon else { throw ActionFailure(message: RefusalStrings.daemonConnecting) }
        guard let connection = daemon.connection else {
            throw ActionFailure(message: daemon.notConnectedReason ?? RefusalStrings.daemonConnecting)
        }
        guard serves(daemon) else { throw ActionFailure(message: daemon.missingCapabilityMessage(DaemonCapability.stash.rawValue)) }
        return connection.state
    }

    /// `error` as the user-facing reason the page shows.
    private static func failure(_ error: any Error) -> any Error {
        error is ActionFailure ? error : ActionFailure(message: RefusalStrings.describe(error))
    }
}
