#if os(iOS)
import CmuxMobileFeed
import Foundation

/// A terminal agent's question in the Feed is answered on its own Mac's
/// terminal (`TerminalFeed.answer`), whichever Mac is chosen.
extension MultiMacFeedActions {
    func terminalOwner(_ item: FeedItem) async throws -> TerminalFeed {
        guard let coordinator = coordinatorForTerminal, let macID = macID(of: item) else {
            throw Unsent(message: FeedStore.notConnectedMessage)
        }
        let name = coordinator.store.teams.flatMap(\.macs).first { $0.id == macID }?.name ?? "your Mac"
        guard coordinator.canLink(macID: macID) else {
            throw Unsent(message: "Only the owner of \(name) can answer from a phone. Nothing was sent.")
        }
        coordinator.touch(macID)
        guard let session = coordinator.sessions[macID] else { throw Unsent(message: "\(name) is offline. Nothing was sent.") }
        let ready = await coordinator.waitUntil(within: linkTimeout) { session.workspaces.daemon != nil }
        guard ready else { throw Unsent(message: "Couldn't connect to \(name). Nothing was sent.") }
        return session.terminalFeed
    }
}
#endif
