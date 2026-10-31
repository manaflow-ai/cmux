import CmuxHomeCore
import CmuxNextDaemon
import CmuxNextHome
import CmuxNextHomeEngine
import Foundation
import os

/// New Chief on this Mac's Chief owner (UniiChat and Codex, ``ChiefBackend/createsOnThisMac``)
/// and the engines the Home list's Chief rows show as badges.
extension HomeService {
    /// A Chief of this Mac's Chief owner that starts on `backend` (`chief.profile.create` with
    /// `harness`), and the person's direct message with it, which the page then shows.
    func createLocalChief(named name: String, backend: ChiefBackend) async -> HomeComposeOutcome {
        guard let connection else { return .offline }
        do {
            let made = try await HomeLocalChiefCreator(connection: connection, me: Self.localUser).create(name: name, backend: backend)
            pendingSelection = made.conversation
            refreshChiefHarnesses()
            return .opened(made.conversation)
        } catch let error as DaemonError {
            switch error {
            case .notConnected, .connectionClosed, .daemonShutdown: return .offline
            case .command(_, let message, let code, _, _): return .refused(message.isEmpty ? code ?? "" : message)
            default: return .refused(error.description)
            }
        } catch {
            return .refused(String(describing: error))
        }
    }

    /// Opens the person's direct message with each of this Mac's Chiefs that has none, so a Chief
    /// made outside New Chief (a Chief's chiefs tool, `cmux chief new`) is in the Home list and the
    /// pinned Chief row at once (``HomeChiefDirectMessages``). Runs after each conversation-list read,
    /// so a Chief whose direct message exists is never opened twice.
    func openChiefDirectMessages() {
        guard let connection else { return }
        let direct = Set(conversations.filter { $0.participants.count == 2 }.flatMap { $0.participants.map(\.id) })
        let opener = HomeChiefDirectMessages(connection: connection, me: Self.localUser)
        // task-owner: one chief.profile.list and an idempotent conversation-create per Chief without one;
        // the owner's conversation-changed event then lists each new direct message
        Task { [logger] in
            let opened = await opener.open(missingFrom: direct)
            if !opened.isEmpty { logger.info("opened Chief direct messages: \(opened.keys.sorted().joined(separator: ","), privacy: .public)") }
        }
    }

    /// Reads again which engine each of this Mac's Chiefs in the list runs on (engine.json,
    /// else its record) for the Home list's badges, and which of them are deleted (their rows
    /// hide); the list redraws only when one changed.
    func refreshChiefHarnesses() {
        let chiefs = Set(homeStore.rows.filter { !isCloudConversation($0.id) }
            .flatMap { $0.summary.participants.filter(\.isChief).map(\.id.rawValue) })
        let reader = HomeChiefHarnesses(muxHome: HomeBrainHost.muxHome(tag: services.environment.tag), connection: connection)
        // task-owner: one read (an owner call and a few small files off the main actor); ends when it is set
        Task { [weak self] in
            let (harnesses, deleted) = await reader.readWithDeleted(chiefs: chiefs)
            guard let self else { return }
            if let deleted, directory.deletedLocalChiefs != deleted { directory.deletedLocalChiefs = deleted }
            guard directory.chiefHarnesses != harnesses else { return }
            directory.chiefHarnesses = harnesses
        }
    }
}
