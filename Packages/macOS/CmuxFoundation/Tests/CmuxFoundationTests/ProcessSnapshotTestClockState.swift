struct ProcessSnapshotTestClockState {
    var instant = ContinuousClock.now
    var reads = 0
}
