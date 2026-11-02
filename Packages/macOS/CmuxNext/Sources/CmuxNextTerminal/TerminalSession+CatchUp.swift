/// A switch to a terminal whose owner held its output while hidden waits for the newest screen (``TerminalCatchUp``).
extension TerminalSession {
    func renderingSuspendedChanged() {
        frameChanges.wake()
        // Asked before the App tells the IO it shows again: then the IO no longer holds anything.
        catchUp.renderingSuspended(isRenderingSuspended, session: self, catchesUp: surfaceHasContent && io.catchesUpWhenShown)
    }

    /// Output went on the surface's lane: a held frame follows it.
    func contentQueued() {
        frameHold.contentQueued()
    }

    /// A whole screen went on the lane (a replay, a READY): a held frame follows it, and it is the current screen a
    /// waiting switch shows once drawn (a new link's first screen: its attach started shown, so no marker comes).
    func screenQueued() {
        frameHold.contentQueued()
        catchUp.caughtUp()
    }

    func endHolds() {
        frameHold.end()
        catchUp.finish()
    }

    /// A switch to this terminal waits: shown again, it has not drawn the output its owner held while it was hidden.
    public var awaitsCatchUp: Bool { catchUp.isPending }

    /// Hidden now, a switch to it would wait for the output its owner holds: it printed since it hid
    /// (``TerminalIO/catchesUpWhenShown``).
    public var catchesUpWhenShown: Bool {
        isRenderingSuspended && surfaceHasContent && io.catchesUpWhenShown && catchUp.printedSinceHide(surfaceView)
    }

    /// Runs `body` once a switch to it may show it (at once when none waits).
    public func whenCaughtUp(_ body: @escaping () -> Void) { catchUp.whenCaughtUp(body) }
}
