actor CameraJournalLockRaceProbe {
    private var firstEvent: CameraJournalLockRaceEvent?
    private var eventContinuation: CheckedContinuation<CameraJournalLockRaceEvent, Never>?

    func publish(_ event: CameraJournalLockRaceEvent) {
        guard firstEvent == nil else { return }
        firstEvent = event
        eventContinuation?.resume(returning: event)
        eventContinuation = nil
    }

    func nextEvent() async -> CameraJournalLockRaceEvent {
        if let firstEvent { return firstEvent }
        return await withCheckedContinuation { eventContinuation = $0 }
    }
}
