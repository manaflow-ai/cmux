import CmuxNextCompat
import CmuxNextHomeEngine

/// Chief teleport in Home: Home follows this Mac's Chief wherever `cmux chief move` took it, with no
/// step from the person (a963, 2026-11-03), and the location chip shows on its conversation.
extension HomeService {
    /// Where this Mac's Chief went (`AppServices.chiefTeleport`, which follows its home's
    /// `moved.json` with a file watch) and the conversation Home follows it to: a hosted Chief's
    /// main conversation for cmux Cloud. A Chief moved to an SSH host or a Mac mini stays "away":
    /// Home has no path to a Chief home on another machine yet (`host serve` splices only the main
    /// session, chief-migration-DESIGN.md 7), so no host is reachable and the chip says where it is.
    var chiefFollow: HomeChiefFollow {
        HomeChiefFollow(whereabouts: services.chiefTeleport.whereabouts, chiefs: directory.chiefs, reachableHost: nil)
    }

    /// Whether `conversation` shows the Chief's location chip: this Mac's default Chief (the one
    /// `cmux chief move` moves), or the conversation Home followed it to.
    func showsTeleport(conversation: String) -> Bool {
        HomeChiefName.select(from: conversations)?.id == conversation || chiefFollow.conversation == conversation
    }

    /// A teleport or a return (the marker written or removed, or the moved Chief's record read)
    /// re-runs the Chief tab check, so the tab and the page follow the Chief. The stream emits only
    /// the follow decision, so an unrelated directory change wakes nothing.
    func observeChiefTeleport() {
        let teleport = services.chiefTeleport
        teleport.startFollowing()
        // task-owner: lives as long as the service; event-driven (Observation over the marker's file watch)
        chiefTeleportObservation = Task { [weak self] in
            for await _ in ObservationStream({ [weak self] in self?.chiefFollow }).dropFirst() {
                self?.refreshChiefTab()
            }
        }
    }
}
