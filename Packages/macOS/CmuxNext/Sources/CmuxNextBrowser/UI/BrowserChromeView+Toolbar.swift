import AppKit
import CmuxNextDesign

// The toolbar row hides while the page is in pane fullscreen, or while the
// person hid it (Toggle Omnibar).
//
// A change lays the rows out once and moves them on the render server, as
// Chrome's browser controls do (cc/input/browser_controls_offset_manager.cc:
// the controls move by a compositor offset and the page is not laid out per
// frame). The row keeps its height and parks past its edge, the page takes its
// rest size in that one layout, and every row that moved springs from where it
// showed by an additive `position.y` (`RenderSpring`). A gap the moving page
// leaves shows the chrome's own fill, as Chrome's gutter does
// (content/browser/renderer_host/delegated_frame_host.cc).
extension BrowserChromeView {
    /// Toggle Omnibar (`palette.browserToggleOmnibar`): hides the address bar
    /// row of this tab, or shows it again. Pane fullscreen still hides it.
    public func toggleOmnibar() {
        isOmnibarHidden.toggle()
        setToolbarHidden(isOmnibarHidden || tab.state.isContentFullscreen)
    }

    func setToolbarHidden(_ hidden: Bool) {
        guard hidden != isToolbarHidden else { return }
        // A strip pinned to the band is the pane's and cannot follow the slide: with the band
        // open, and outside a window, every row lands in one frame.
        let slides = window != nil && (headerBand.height?.constant ?? 0) == 0
        // Two changes before one layout start from the frames the first one found.
        let slide = slides ? pendingToolbarSlide ?? ToolbarSlide(self) : nil
        isToolbarHidden = hidden
        toolbarToggles &+= 1
        if !hidden { toolbar.isHidden = false; separator.isHidden = false }
        toolbar.alphaValue = hidden ? 0 : 1
        accessoryBar.isHidden = hidden
        applyAccessoryHeight()
        syncHeaderBand(animated: false)
        // invalidate: the rows move (`toolbarRowHeight`, the parked row); that one layout starts the slide.
        needsLayout = true
        pendingToolbarSlide = slide
        guard slide == nil else { return }
        for layer in subviews.compactMap(\.layer) { RenderSpring.stop(layer, RenderSpringKey<CGFloat>.positionY.path) }
        if let layer = toolbar.layer { RenderSpring.stop(layer, RenderSpringKey<CGFloat>.opacity.path) }
        landToolbarToggle(toolbarToggles)
    }

    /// Called at the end of `layout()`: the rows are at rest, so each one that moved springs
    /// from where it showed, and the row fades, in one group (the gate decides what animates).
    func startToolbarSlide() {
        guard let slide = pendingToolbarSlide else { return }
        pendingToolbarSlide = nil
        var moves: [RenderSpring.Move] = []
        // A resize in the same turn (the pane moved, a window came back) is no slide: the rows land.
        let rows = slide.size == bounds.size ? subviews.filter { !$0.isHidden } : []
        for view in rows {
            guard let layer = view.layer, let old = slide.frames[ObjectIdentifier(view)] else { continue }
            let shift = Self.rowShift(from: old, to: view.frame, flipped: isFlipped)
            guard shift != 0 else { continue }
            let y = layer.position.y
            moves.append(RenderSpring.Move(layer, RenderSpringKey<CGFloat>.positionY, from: y + shift, to: y))
        }
        if let layer = toolbar.layer, slide.opacity != toolbar.alphaValue {
            moves.append(RenderSpring.Move(layer, RenderSpringKey<CGFloat>.opacity, from: slide.opacity, to: toolbar.alphaValue))
        }
        let toggle = toolbarToggles
        Motion.overlays.renderSpring(isToolbarHidden ? .disappear : .appear).animateGroup(moves, in: self) { [weak self] _ in
            // A newer change owns the row (`toolbarToggles`), whether or not this one finished.
            self?.landToolbarToggle(toggle)
        }
    }

    /// The `position.y` offset that shows a row where it was: a row that kept its height moves
    /// whole; one that resized (the page area) keeps its top edge, where page content is anchored.
    static func rowShift(from old: CGRect, to new: CGRect, flipped: Bool) -> CGFloat {
        (old.height == new.height || flipped) ? old.minY - new.minY : old.maxY - new.maxY
    }

    /// The landing of change number `toggle`: a hidden row stops drawing.
    func landToolbarToggle(_ toggle: Int) {
        guard toggle == toolbarToggles, isToolbarHidden else { return }
        toolbar.isHidden = true
        separator.isHidden = true
    }
}

/// Where the chrome's rows showed before a toolbar change, and the row's opacity.
struct ToolbarSlide {
    let frames: [ObjectIdentifier: CGRect]
    let opacity: CGFloat
    let size: CGSize

    @MainActor init(_ chrome: BrowserChromeView) {
        frames = Dictionary(uniqueKeysWithValues: chrome.subviews.map { (ObjectIdentifier($0), $0.frame) })
        opacity = chrome.toolbar.alphaValue
        size = chrome.bounds.size
    }
}
