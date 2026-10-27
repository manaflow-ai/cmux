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

    /// What reopening a linked tab came to, for the reveal on main.
    enum Reopened: Equatable, Sendable {
        /// A daemon reopened it and its store lists it.
        case listed
        /// A daemon reopened it, but its store did not list it within ``listLimit``.
        case notListed
        /// No daemon holds it.
        case gone
        /// A daemon failed for another reason (its message, when it gave one).
        case failed(String?)
    }

    /// Reopens closed tab `id` and reveals it: `link.open`'s path for a tab
    /// link whose tab is not open (``DeepLinkNavigator``). The failure, if
    /// any, is the tracked work's result. The reveal is the run's end, one task on main in the run's class
    /// (`userBlocking` for the person's click, ``ActionRegistry/trackWork(owner:on:tracked:file:line:_:then:)``).
    static func open(_ id: String, intent: WindowActivation.Intent, services: AppServices) {
        let source = services.windows.active?.focusedPane
        let fallback = source.flatMap { fallbackPane(from: $0, services: services) }
        let daemons = services.machines.daemons.filter { $0.connection != nil }
        services.registry.trackWork(owner: "DurableTabLink.open", on: services.mainWork) {
            await reopenAndList(id, on: daemons, fallback: fallback)
        } then: { result in
            switch result {
            case .success(.listed):
                if services.revealTab(id, intent: intent) { return nil }
                return ActionWorkFailure(RefusalStrings.linkTargetGone, mayHaveApplied: true)
            case .success(.notListed):
                return ActionWorkFailure(RefusalStrings.linkTargetGone, mayHaveApplied: true)
            case .success(.gone):
                services.registry.refuse(RefusalStrings.linkTargetGone)
                return ActionWorkFailure(refusal: .unavailable, reason: RefusalStrings.linkTargetGone)
            case .success(.failed(let failure)):
                return ActionWorkFailure(failure ?? RefusalStrings.linkTargetGone, mayHaveApplied: true)
            case .failure(let error):
                return ActionWorkFailure(RefusalStrings.describe(error), mayHaveApplied: true)
            }
        }
    }

    /// Asks each daemon to reopen tab `id` (``reopen(on:_:)``), then waits for the one that did to list it: its
    /// store's keyed wait (StoreWaiters), read again only when that store keys the tab's resource id. Main-actor:
    /// the daemon services are; each step's daemon command runs off main.
    private static func reopenAndList(_ id: String, on daemons: [DaemonService],
                                      fallback: (daemon: DaemonService, pane: String)?) async -> Reopened {
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
        case .reopened(let index):
            let listed = await daemons[index].store.waitForTab(resource: ResourceID(rawValue: id), timeout: listLimit)
            return listed == nil ? .notListed : .listed
        case .gone:
            return .gone
        case .failed:
            return .failed(failure)
        }
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
}
