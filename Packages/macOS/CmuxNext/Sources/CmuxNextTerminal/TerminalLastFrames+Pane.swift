public import AppKit
public import CmuxNextWakeups

/// What a pane's content area shows of a terminal's saved frames (SWITCH FRAMES item 2), in one place for the pane: an
/// evicted terminal's last frame (``TerminalLastFrames``) first, else its frame from the last quit (``TerminalLaunchFrames``).
extension TerminalLastFrames {
    /// The pane waits for the surface of tab `key` (one new surface per display frame): it shows the tab's saved frame on
    /// one layer at once. `key` nil: the pane does not wait for a terminal (hidden, suspended, another kind of tab), and a
    /// frame shown ahead of another tab goes now: no frame mixes two tabs (L4).
    public mutating func paneWaits(_ key: String?, in content: NSView, launch: TerminalLaunchFrames) { // perf-hot: 1ms workspace-switch (each waiting pane)
        guard let key else { return withdrawAhead(in: content) }
        if !showAhead(key, in: content) { launch.showAhead(key, in: content) }
    }

    /// The pane shows `shown`, tab `key`'s view, in `content`. A frame shown ahead goes in this turn (the revealed
    /// session took its own over already, ``show(_:on:)``), and a terminal takes its frame from the last quit over and
    /// keeps its frame on disk while the app runs; other content is shown with no frame under it.
    public mutating func paneShows(_ key: String?, view shown: NSView?, in content: NSView, launch: TerminalLaunchFrames, work: BackgroundWork) {
        withdrawAhead(in: content)
        guard let key, let session = (shown as? TerminalHostView)?.current?.session else { return launch.withdrawAhead(in: content) }
        launch.show(key, on: session, in: content)
        launch.keep(key, session: session, work: work)
    }

    /// The pane goes: no frame stays pinned for it.
    public mutating func paneGoes(in content: NSView, launch: TerminalLaunchFrames) {
        launch.withdrawAhead(in: content)
        withdrawAhead(in: content)
    }
}
