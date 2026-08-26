import AppKit

@MainActor
final class BrowserOffscreenRenderPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
