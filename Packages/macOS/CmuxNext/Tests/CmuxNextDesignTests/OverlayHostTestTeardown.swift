import AppKit
@testable import CmuxNextDesign

extension NSWindow {
    /// A test's teardown for a window it made: closes the window and the overlay panel its
    /// `WindowOverlayHost` keeps. Closing the window tears the host down, which only orders the
    /// panel out, and a window never closed keeps its host (and panel) for the whole process
    /// (`.closesItsWindows`).
    func closeWithOverlayHost() {
        let panel = WindowOverlayHost.existingHost(for: self)?.panel
        isReleasedWhenClosed = false
        close()
        panel?.close()
    }
}
