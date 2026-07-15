nonisolated enum VerifiedReplayFreezeDrainPolicy {
    static func requiresPresentedDrain(hasPresentedContents: Bool) -> Bool {
        hasPresentedContents
    }
}
