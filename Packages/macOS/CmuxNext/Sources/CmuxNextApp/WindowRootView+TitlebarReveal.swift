import AppKit
import CmuxNextDesign

// R83: the sidebar toggle, Back, Forward and a glass patch under the traffic
// lights stay hidden until the pointer is over the sidebar or the top row
// above it, then fade in, in place, through the one hover-reveal mechanism
// (HoverReveal; the sidebar's hover is a hold on it). The toggle joined them
// on Lawrence's word (cx-uxdr, 2026-10-08: "toggle sidebar button should hide
// when im not hovered on sidebar"). Shortcuts, the View menu and the palette
// reach the same actions while they are hidden; keyboard focus on a hidden
// button reveals them, and they stay in the accessibility tree.
extension WindowRootView {
    func setUpTitlebarReveal() {
        // The mode first: `add` sets each button's alpha from it at once. A fade run
        // before this view joins a window never applies, so the buttons stayed at 0
        // with the sidebar open until it was hidden and shown again.
        applyTitlebarButtonsMode()
        titlebarReveal.add(toolbarBand.sidebarToggle)
        titlebarReveal.add(toolbarBand.backButton)
        titlebarReveal.add(toolbarBand.forwardButton)
        // The glass patch is a hover cue only: it never shows at rest.
        trafficLightsGlass.alphaValue = 0
        titlebarReveal.onChange = { [weak self] revealed in
            guard let self else { return }
            let glass = trafficLightsGlass
            Motion.feedback.animate(.hover, in: glass) { glass.animator().alphaValue = revealed && self.titlebarReveal.state.pointerInside ? 1 : 0 }
        }
        // The pointer over a shown or floating sidebar shows its chrome: its + button and these buttons above it.
        sidebar.sidebarView.onChromeRevealChange = { [weak self] revealed in
            guard let self else { return }
            if revealed, !sidebarHidden || sidebar.model.isFloating {
                if sidebarHoverHold == nil { sidebarHoverHold = titlebarReveal.hold() }
            } else {
                endSidebarHoverHold()
            }
        }
    }

    /// Revealed by the pointer, or the band open through its close delay: the zone is the whole top row.
    var titlebarRevealIsSticky: Bool { titlebarReveal.state.pointerInside || collapsedBand.isOpen }

    func endSidebarHoverHold() { sidebarHoverHold?.release(); sidebarHoverHold = nil }

    /// Whether the buttons hide at rest. With the sidebar open they always
    /// show, as its + button does (Lawrence 2026-10-28 message 15460: "if
    /// sidebar is open, all the stuff should show"), unless Minimal Mode or Show
    /// Sidebar Controls Only on Hover is on (``SidebarSectionsPreferences/hidesControlsUntilHover``). With the
    /// sidebar hidden, `window.titlebarButtons` decides: hover (the default)
    /// hides them at rest; always shows them.
    func applyTitlebarButtonsMode() {
        let design = DesignSettings.shared
        let hidesAtRest = sidebarHidden ? design.titlebarButtons == .hover : design.sidebarSections.hidesControlsUntilHover
        if titlebarReveal.isEnabled != hidesAtRest { titlebarReveal.isEnabled = hidesAtRest }
    }

    /// The region is the top row above a left sidebar, else (a right or hidden sidebar) the traffic lights and the
    /// open band's toggle slot, the toggle plus its padding but not Back and Forward; once revealed
    /// (``titlebarRevealIsSticky``) the whole top row, so the buttons stay until the pointer leaves the tab bar (Leo
    /// 2026-11-27: "they should stay until you move out of the top tab area / ... should only be around the sidebar
    /// toggle + maybe its constituent padding? including the back AND the forward button is a bit big..."). The open
    /// band's extent, never its 0-wide collapsed frame (Lawrence 2026-10-09); the zone grows only under a pointer inside
    /// it and shrinks only with the pointer out of the row, so its edge never moves under the pointer (no flicker).
    func layoutTitlebarReveal(rowHeight: CGFloat, openForwardMaxX: CGFloat, openToggleMaxX: CGFloat) {
        let sidebarMaxX = sidebarSide == .left && !sidebar.isHidden ? sidebar.frame.maxX : 0
        let width = sidebarMaxX > 0 ? max(sidebarMaxX, openForwardMaxX) : titlebarRevealIsSticky ? bounds.width : openToggleMaxX
        titlebarRevealRegion.frame = CGRect(x: 0, y: bounds.maxY - rowHeight, width: min(bounds.width, width), height: rowHeight)
        guard let window, let lights = WindowTitlebar.trafficLightsFrame(in: window) else {
            trafficLightsGlass.frame = .zero
            return
        }
        let local = convert(lights, from: nil).insetBy(dx: -Metrics.space2, dy: -Metrics.space1)
        trafficLightsGlass.frame = local
    }
}

/// A view that tracks the pointer but never takes a click.
final class PassThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The hover patch behind the traffic lights: the chrome hover fill on a
/// rounded rect, repainted with the theme. Takes no clicks.
final class TrafficLightsPatch: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Metrics.panelCornerRadius
        layer?.cornerCurve = .continuous
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyColors()
    }

    private func applyColors() {
        performWithTheme { layer?.backgroundColor = Palette.hoverFill.cgColor }
    }
}
