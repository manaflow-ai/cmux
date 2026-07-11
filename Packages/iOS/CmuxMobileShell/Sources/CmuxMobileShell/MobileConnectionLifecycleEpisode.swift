/// The token and accumulated demand owned by one recovery episode.
struct MobileConnectionLifecycleEpisode: Equatable {
    var id: UInt64
    var kind: MobileConnectionLifecycleRecoveryKind
    var triggers: Set<MobileConnectionLifecycleTrigger>
    var requestIDs: Set<UInt64>
    var reconnectStackUserID: String?
}
