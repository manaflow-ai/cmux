import CmuxHomeCore
import CmuxNextDaemon
import CmuxNextHome
import CmuxNextHomeEngine
import Foundation

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

    /// Reads again which engine each of this Mac's Chiefs in the list runs on (engine.json,
    /// else its record) for the Home list's badges; the list redraws only when one changed.
    func refreshChiefHarnesses() {
        let chiefs = Set(homeStore.rows.filter { !isCloudConversation($0.id) }
            .flatMap { $0.summary.participants.filter(\.isChief).map(\.id.rawValue) })
        let reader = HomeChiefHarnesses(muxHome: HomeBrainHost.muxHome(tag: services.environment.tag), connection: connection)
        // task-owner: one read (an owner call and a few small files off the main actor); ends when it is set
        Task { [weak self] in
            let harnesses = await reader.read(chiefs: chiefs)
            guard let self, directory.chiefHarnesses != harnesses else { return }
            directory.chiefHarnesses = harnesses
        }
    }
}
