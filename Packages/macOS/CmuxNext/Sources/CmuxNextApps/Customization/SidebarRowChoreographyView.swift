import AppKit
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextWakeups

/// Plays a sidebar row's particles glyph (``SidebarRowGlyph``, `cmux.sidebar.rows/1`
/// `indicator: {choreography, trigger}` or `"glyph"`) in the row's loading indicator cell, with the
/// scene renderer's native player (``AppSceneChoreographyGlyph``: one layer per dot moved only by its
/// transform, on the window's one motion clock behind ``Motion/appScenes``). Leo, 2026-11-19: "the dots
/// and the way it moves changes a lot".
///
/// A row's own document was checked by the app host's validator with its scene (particles.rs
/// `sanitize_scene_ops`, `indicator.choreography`); `"glyph"` plays the look's
/// `agentPane.display.thinking.glyph`, which the settings owner checked (``StatusIndicatorAppearance/lookGlyph``). A document
/// the player cannot read draws nothing. The dots run only while the indicator would animate (window
/// on screen, row shown, loops on); otherwise they hold where they are.
@MainActor
final class SidebarRowChoreographyView: NSView, SidebarRowGlyphPlayer {
    var view: NSView { self }
    private var glyph: AppSceneChoreographyGlyph?
    /// The document text the running glyph plays, so a refresh with the same one parses nothing.
    private var playingText: String?
    /// The indicator's gate: whether the dots may run (window on screen, row shown, loops on).
    private var runs = false
    private weak var followedWindow: NSWindow?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func play(_ requested: SidebarRowGlyph?, animates: Bool) {
        runs = animates
        guard let requested, let text = requested.document ?? StatusIndicatorAppearance.shared.lookGlyph() else { return clear() }
        let request = AppSceneChoreography.Request(trigger: requested.trigger)
        if let glyph, text == playingText {
            glyph.setRequest(request)
        } else {
            clear()
            guard let document = try? AppJSON.parse(text), let choreography = AppSceneChoreography(json: document) else { return }
            let made = AppSceneChoreographyGlyph(document: document, choreography: choreography, request: request)
            layer?.addSublayer(made.host)
            glyph = made
            playingText = text
            needsLayout = true
        }
        observeSight()
        updateClock()
    }

    private func clear() {
        glyph?.stop()
        glyph?.host.removeFromSuperlayer()
        glyph = nil
        playingText = nil
    }

    /// Runs the dots while the indicator animates; otherwise they hold.
    private func updateClock() {
        guard let glyph else { return }
        if runs, window != nil { glyph.update(in: self) } else { glyph.stop() }
    }

    override func layout() {
        super.layout()
        guard let glyph else { return }
        // Rows use the document's own size (only Jump to latest takes glyphSize).
        glyph.layout(center: CGPoint(x: bounds.midX, y: bounds.midY), size: CGFloat(glyph.choreography.size))
        paint()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeSight()
        updateClock()
    }

    /// `particle.color` (a scene token or `#RRGGBB[AA]`), else the accent, in the view's theme scope.
    private func paint() {
        guard let glyph else { return }
        performWithTheme {
            let color = AppJSON.string(glyph.choreography.color).sceneColor ?? Palette.accentFill
            glyph.paint(color: color.cgColor)
        }
    }

    /// Back in sight, the dots run again (the app's one occlusion observer).
    private func observeSight() {
        guard followedWindow !== window else { return }
        if let followedWindow { FrameScheduler.unfollowSight(of: followedWindow, owner: self) }
        followedWindow = window
        guard let window else { return }
        FrameScheduler.followSight(of: window, owner: self) { [weak self] in self?.updateClock() }
    }
}
