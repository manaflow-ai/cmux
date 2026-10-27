public import AppKit
import CmuxNextDesignTokens

extension BackdropVideoView {
    /// Samples how much of the window other windows hide, and rests or resumes the video on it. The
    /// window server's list (a synchronous call that waits for it) runs on the system lane of
    /// ``BackdropVideoPlayers/lanes`` at best effort, never on the main thread; the answer applies on main
    /// against the window frame read with it. At most one list is pending per view: a deadline that comes
    /// while one is pending samples nothing, so a slow window server never queues more.
    public func sampleCoverage() {
        guard let window else { return }
        if let windowsAboveOverride { return applyCoverage(windowsAboveOverride(), frame: window.frame, in: window) }
        guard coverageSample == nil, let lanes = players.lanes else { return }
        let number = window.windowNumber, frame = window.frame
        // task-owner: this view (`coverageSample`); one window list, cancelled by stopCoverage, which also drops a queued one.
        coverageSample = Task(priority: .utility) { [weak self] in
            let above = try? await lanes.runSystem(.bestEffort, { BackdropCoverage.windows(above: number) })
            // A cancelled sample was already let go by stopCoverage, which may have started a new one since.
            guard let self, !Task.isCancelled else { return }
            self.coverageSample = nil
            guard let above, let window = self.window, window.windowNumber == number else { return }
            self.applyCoverage(above, frame: frame, in: window)
        }
    }

    private func applyCoverage(_ above: [BackdropCoverage.Window], frame: NSRect, in window: NSWindow) {
        let resting = coverage.resting
        coverage.sample(BackdropCoverage.covered(Self.screenFrame(frame), by: above, ignoring: Self.descendants(of: window)))
        if coverage.resting != resting { update() }
    }

    /// The numbers of a window's child windows, theirs, and so on: its overlay panel and page windows.
    static func descendants(of window: NSWindow) -> Set<Int> {
        var numbers: Set<Int> = []
        var pending = window.childWindows ?? []
        while let child = pending.popLast() {
            // A child never put on screen has no number yet; 0 would hide every unnumbered window.
            if child.windowNumber > 0 { numbers.insert(child.windowNumber) }
            pending += child.childWindows ?? []
        }
        return numbers
    }

    /// A window frame in CGWindowList's space: origin at the top left of the main display.
    static func screenFrame(_ frame: NSRect) -> CGRect {
        let top = NSScreen.screens.first?.frame.maxY ?? frame.maxY
        return CGRect(x: frame.minX, y: top - frame.maxY, width: frame.width, height: frame.height)
    }
}
