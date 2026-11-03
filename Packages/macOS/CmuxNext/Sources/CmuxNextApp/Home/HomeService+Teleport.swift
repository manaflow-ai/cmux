import CmuxNextHomeEngine

/// Chief teleport in Home: which conversations show the Chief's location chip.
extension HomeService {
    /// Whether `conversation` is the Chief `cmux chief move` moves: this Mac's default Chief.
    func showsTeleport(conversation: String) -> Bool {
        HomeChiefName.select(from: conversations)?.id == conversation
    }
}
