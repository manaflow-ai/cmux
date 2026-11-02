/// A switch to a terminal whose owner held its output while hidden waits for the newest screen (``TerminalCatchUp``).
extension TerminalSession {
    func renderingSuspendedChanged() {
        frameChanges.wake()
        // Asked before the App tells the IO it shows again: then the IO no longer holds anything.
        catchUp.renderingSuspended(isRenderingSuspended, surface: surfaceView,
                                   catchesUp: surfaceHasContent && io.catchesUpWhenShown)
    }

    /// Content went on the surface's lane: a held frame and a waiting switch follow it.
    func contentQueued() {
        frameHold.contentQueued()
        catchUp.contentQueued()
    }

    func endHolds() {
        frameHold.end()
        catchUp.finish()
    }

    /// A switch to this terminal waits: shown again, it has not drawn the output its owner held while it was hidden.
    public var awaitsCatchUp: Bool { catchUp.isPending }

    /// Hidden now, a switch to it would wait for the output its owner holds (``TerminalIO/catchesUpWhenShown``).
    public var catchesUpWhenShown: Bool { isRenderingSuspended && surfaceHasContent && io.catchesUpWhenShown }

    /// Runs `body` once a switch to it may show it (at once when none waits).
    public func whenCaughtUp(_ body: @escaping () -> Void) { catchUp.whenCaughtUp(body) }
}
