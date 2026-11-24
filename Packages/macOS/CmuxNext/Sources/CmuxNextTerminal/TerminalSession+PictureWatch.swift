import CmuxNextWakeups

extension TerminalSession {
    /// A hover card shows this terminal's picture (`PanePictureWatch`, #51768): the terminal keeps drawing while it
    /// is out of sight (a mirror, ``mirrorDemand``), and `changed` runs on the main actor once the frame after a
    /// change reached the screen (so the picture has it): at its first change after this call and after each
    /// ``TerminalFrameChanges/rearmWatch()`` (once per picture, not once per output chunk), and once at the first frame
    /// drawn after the watch starts (a hidden terminal drawing again for the card). Returns the stop, which runs once.
    /// Before each picture, ``rearmPictureWatch()``.
    public func watchPicture(_ changed: @escaping @MainActor @Sendable () -> Void) -> @MainActor () -> Void {
        let presented: @Sendable () -> Void = { MainDelivery().run(changed) }  // once per frame a shown card waits for
        // The surface showing now; a surface swap while the card shows (a reattach) is pictured at the next watch.
        let presents = surfaceView.bridge.takeUnretainedValue().presents
        pictureWatchPresented = presented
        frameChanges.watch { presents.onNextPresent(presented) }  // on the changing thread, before its frame can show
        presents.onNextPresent(presented)
        mirrorDemand += 1  // after the watch: the frame this draws is told
        var stopped = false
        return { [weak self] in
            guard !stopped, let self else { return }
            stopped = true
            self.mirrorDemand = max(0, self.mirrorDemand - 1)
            self.frameChanges.stopWatching()
            self.pictureWatchPresented = nil
            presents.onNextPresent {}
        }
    }

    /// A picture of the watched terminal starts: the next change tells the watch again, and a change since the last
    /// tell (its frame maybe not shown yet) asks for one more picture after the next frame shows.
    public func rearmPictureWatch() {
        guard frameChanges.rearmWatch(), let presented = pictureWatchPresented else { return }
        surfaceView.bridge.takeUnretainedValue().presents.onNextPresent(presented)
    }
}
