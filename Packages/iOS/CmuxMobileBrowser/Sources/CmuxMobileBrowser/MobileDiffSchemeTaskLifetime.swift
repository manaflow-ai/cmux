/// Serializes WebKit scheme-task callbacks and cancellation without blocking WebKit.
actor MobileDiffSchemeTaskLifetime {
    private var activeTasks: Set<ObjectIdentifier> = []
    private var stoppedBeforeRegistration: Set<ObjectIdentifier> = []

    func register(_ taskID: ObjectIdentifier) {
        if stoppedBeforeRegistration.remove(taskID) != nil {
            return
        }
        activeTasks.insert(taskID)
    }

    func performCallback(
        _ taskID: ObjectIdentifier,
        _ callback: @Sendable () -> Void
    ) -> Bool {
        guard activeTasks.contains(taskID) else { return false }
        callback()
        return true
    }

    func finish(_ taskID: ObjectIdentifier) {
        stop(taskID)
    }

    func stop(_ taskID: ObjectIdentifier) {
        if activeTasks.remove(taskID) == nil {
            stoppedBeforeRegistration.insert(taskID)
        }
    }
}
