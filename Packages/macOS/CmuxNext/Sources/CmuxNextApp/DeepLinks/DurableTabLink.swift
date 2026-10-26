import CmuxNextActions
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextWakeups
import Foundation

/// A `cmux://tab/tab_…` link to a tab that is not open
/// (plans/cmux-next/durable-links-DESIGN.md): the daemon that still holds the
/// tab in its closed history reopens it by its id, under that SAME id, in its
/// old place (else where a link clicked from the focused pane opens new
/// items, ``LinkOpener``), and the link then reveals it like an open tab.
/// No daemon holding it is the gone refusal; nothing else opens in its place.
@MainActor
enum DurableTabLink {
    /// One daemon's answer to "reopen this tab".
    enum Answer: Equatable {
        /// It held the tab and reopened it.
        case reopened
        /// No closed group of it holds the tab.
        case notInHistory
    }

    /// What the walk over the daemons came to.
    enum Outcome<Daemon: Equatable>: Equatable {
        /// `on` reopened the tab.
        case reopened(on: Daemon)
        /// No daemon holds it.
        case gone
        /// `on` failed for another reason; the walk stopped there.
        case failed(on: Daemon)
    }

    /// Asks each daemon in order (local first) until one reopens the tab.
    ///
    /// - Parameters:
    ///   - daemons: The connected daemons, local first.
    ///   - ask: Reopens the tab on one daemon; throws on a failure other than
    ///     "not in its history".
    /// - Returns: The daemon that reopened it, else gone, else the failing one.
    static func reopen<Daemon: Equatable>(
        on daemons: [Daemon],
        _ ask: (Daemon) async throws -> Answer
    ) async -> Outcome<Daemon> {
        for daemon in daemons {
            do {
                if try await ask(daemon) == .reopened { return .reopened(on: daemon) }
            } catch {
                return .failed(on: daemon)
            }
        }
        return .gone
    }

    /// How long the reveal waits for the store to list the reopened tab.
    static let listLimit: Duration = .seconds(30)

    /// Reopens closed tab `id` and reveals it: `link.open`'s path for a tab
    /// link whose tab is not open (``DeepLinkNavigator``). The failure, if
    /// any, is the tracked work's result.
    static func open(_ id: String, intent: WindowActivation.Intent, services: AppServices) {
        let source = services.windows.active?.focusedPane
        let fallback = source.flatMap { fallbackPane(from: $0, services: services) }
        let daemons = services.machines.daemons.filter { $0.connection != nil }
        services.registry.track(Task { @MainActor () -> ActionWorkFailure? in
            var failure: String?
            let outcome = await reopen(on: daemons.indices.map { $0 }) { index in
                let daemon = daemons[index]
                guard let connection = daemon.connection else { return .notInHistory }
                do {
                    let pane = fallback?.daemon === daemon ? fallback?.pane : nil
                    try await connection.state.reopenClosed(tab: id, fallbackPane: pane)
                    await daemon.appliedThroughReply(on: connection, after: "reopen linked tab")
                    return .reopened
                } catch DaemonError.command(_, _, let code, _, _) where code == "resource.not_found" {
                    return .notInHistory
                } catch {
                    daemon.logger.error("closed.reopen {tab} failed: \(String(describing: error), privacy: .public)")
                    failure = "closed.reopen: \(error)"
                    throw error
                }
            }
            switch outcome {
            case .reopened:
                if await reveal(id, intent: intent, services: services) { return nil }
                return ActionWorkFailure(RefusalStrings.linkTargetGone, mayHaveApplied: true)
            case .gone:
                services.registry.refuse(RefusalStrings.linkTargetGone)
                return ActionWorkFailure(refusal: .unavailable, reason: RefusalStrings.linkTargetGone)
            case .failed:
                return ActionWorkFailure(failure ?? RefusalStrings.linkTargetGone, mayHaveApplied: true)
            }
        })
    }

    /// The daemon pane a link clicked from `source` opens new items in
    /// (``LinkOpener``: Home's is the pane on its right), when that is an
    /// existing pane: where a tab whose own pane and workspace are gone goes.
    private static func fallbackPane(from source: PaneController, services: AppServices) -> (daemon: DaemonService, pane: String)? {
        guard case .pane(let id) = services.linkOpener.target(from: source) else { return nil }
        let controller = id == source.layoutPaneID ? source : source.workspace?.panes[id]
        guard let controller, let pane = controller.pane.resourceID?.rawValue else { return nil }
        return (controller.daemon, pane)
    }

    /// Reveals tab `id` once the store lists it (``AppServices/revealTab(_:intent:)``).
    private static func reveal(_ id: String, intent: WindowActivation.Intent, services: AppServices) async -> Bool {
        if services.revealTab(id, intent: intent) { return true }
        let listed = Task { @MainActor () -> Bool in
            // `tabListRevision`: the tracked read hears the tab appear (AppServices.locateTab).
            for await found in ObservationStream({
                for daemon in services.machines.daemons { _ = daemon.store.tabListRevision }
                return services.locateTab(id) != nil
            }) where found {
                return true
            }
            return false
        }
        let bound = DemandTimer(owner: "DurableTabLink.listed")
        bound.schedule(after: listLimit) { @MainActor in listed.cancel() }
        let found = await listed.value
        bound.cancel()
        return found && services.revealTab(id, intent: intent)
    }
}

/// A `cmux://workspace/ws_…` link to a workspace that is not open (cmux#25572: a Chief's
/// reply links the workspaces it names, and the person clicks one after closing it): the
/// daemon that still holds the workspace in its closed history reopens it, as Reopen Closed
/// Workspace would, and the link reveals it. It reopens as a new workspace (a new `ws_` id;
/// keeping the id is the durable-links a343 slice). No daemon holding it is the gone refusal.
@MainActor
enum DurableWorkspaceLink {
    /// Reopens closed workspace `id` and reveals it: `link.open`'s path for a workspace link
    /// whose workspace is not open (``DeepLinkNavigator``). The failure, if any, is the
    /// tracked work's result.
    static func open(_ id: String, intent: WindowActivation.Intent, services: AppServices) {
        let daemons = services.machines.daemons.filter { $0.connection != nil }
        services.registry.track(Task { @MainActor () -> ActionWorkFailure? in
            var failure: String?
            var reopened: (daemon: DaemonService, workspace: ResourceID?)?
            let outcome = await DurableTabLink.reopen(on: daemons.indices.map { $0 }) { index in
                let daemon = daemons[index]
                guard let connection = daemon.connection else { return .notInHistory }
                do {
                    let item = try await connection.state.reopenClosed(workspace: id)
                    await daemon.appliedThroughReply(on: connection, after: "reopen linked workspace")
                    reopened = (daemon, item.workspaceID)
                    return .reopened
                } catch DaemonError.command(_, _, let code, _, _) where code == "resource.not_found" {
                    return .notInHistory
                } catch {
                    daemon.logger.error("closed.reopen {workspace} failed: \(String(describing: error), privacy: .public)")
                    failure = "closed.reopen: \(error)"
                    throw error
                }
            }
            switch outcome {
            case .reopened:
                if let reopened, let workspace = reopened.workspace,
                   let key = await reopened.daemon.store.workspace(afterReopen: workspace, clock: reopened.daemon.reopenClock),
                   let window = services.windows.reveal(workspaceID: key)?.window {
                    services.showJumpWindow(window, intent)
                    return nil
                }
                return ActionWorkFailure(RefusalStrings.linkTargetGone, mayHaveApplied: true)
            case .gone:
                services.registry.refuse(RefusalStrings.linkTargetGone)
                return ActionWorkFailure(refusal: .unavailable, reason: RefusalStrings.linkTargetGone)
            case .failed:
                return ActionWorkFailure(failure ?? RefusalStrings.linkTargetGone, mayHaveApplied: true)
            }
        })
    }
}
