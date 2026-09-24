public import AppKit

@MainActor
public final class BrowserOffscreenRenderPanel: NSPanel {
    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }
}
