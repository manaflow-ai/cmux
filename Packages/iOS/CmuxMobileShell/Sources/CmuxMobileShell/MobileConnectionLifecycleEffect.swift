/// An executable effect emitted by the lifecycle reducer.
enum MobileConnectionLifecycleEffect: Equatable {
    case start(MobileConnectionLifecycleEpisode)
    case updateStreamRepair(
        MobileConnectionLifecycleEpisode,
        restartEventStream: Bool,
        refreshSecondaries: Bool
    )
}
