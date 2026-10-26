public import AppKit
import CmuxNextDesignTokens

extension BackdropVideoView {
    /// Samples how much of the window other windows hide, and rests or resumes the video on it. The
    /// window server's list (a synchronous call that waits for it) runs on the system lane of
    /// ``BackdropVideoPlayers/lanes`` at best effort, never on the main thread; the answer applies on main.
    public func sampleCoverage() {
        guard let window else { return }
        if let windowsAboveOverride { return applyCoverage(windowsAboveOverride(), in: window) }
        guard let lanes = players.lanes else { return }
        let number = window.windowNumber
        // task-owner: one window list per coverage deadline; a view that stopped sampling drops the answer.
        Task(priority: .utility) { [weak self] in
            let above = try? await lanes.runSystem(.bestEffort, { BackdropCoverage.windows(above: number) })
            guard let above, let self, self.coverageTimer.isScheduled, let window = self.window else { return }
            self.applyCoverage(above, in: window)
        }
    }

    private func applyCoverage(_ above: [BackdropCoverage.Window], in window: NSWindow) {
        let resting = coverage.resting
        coverage.sample(BackdropCoverage.covered(Self.screenFrame(window.frame), by: above, ignoring: Self.descendants(of: window)))
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
