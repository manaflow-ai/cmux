import AppKit
import CmuxNextDesign

// The toolbar row hides while the page is in pane fullscreen, or while the
// person hid it (Toggle Omnibar).
//
// With `motion.renderServer` off (the default) the rows' frames animate to the
// new toolbar height on the main thread. With it on, a change lays the rows out
// once and moves them on the render server, as Chrome's browser controls do
// (cc/input/browser_controls_offset_manager.cc: the controls move by a
// compositor offset and the page is not laid out per frame). The row keeps its
// height and parks past its edge, the page takes its rest size in that one
// layout, and every row that moved springs from where it showed by an additive
// `position.y` (`RenderSpring`). A gap the moving page leaves shows the page's
// own background (`pageGutter`), as Chrome's gutter does
// (content/browser/renderer_host/delegated_frame_host.cc). A page in its own
// window (`.childWindow`) is placed from the page host's frame, not its layer,
// so it and the views over it land in that layout and only the rows move.
extension BrowserChromeView {
    /// Toggle Omnibar (`palette.browserToggleOmnibar`): hides the address bar
    /// row of this tab, or shows it again. Pane fullscreen still hides it.
    public func toggleOmnibar() {
        isOmnibarHidden.toggle()
        setToolbarHidden(isOmnibarHidden || tab.state.isContentFullscreen)
    }

    func setToolbarHidden(_ hidden: Bool) {
        guard hidden != isToolbarHidden else { return }
        isToolbarHidden = hidden
        toolbarToggles &+= 1
        if !hidden { toolbar.isHidden = false; separator.isHidden = false }
        accessoryBar.isHidden = hidden
        applyAccessoryHeight()
        if rendersMotionOnServer() { slideToolbar() } else { stepToolbar() }
    }

    /// The main thread animates the rows' frames to the new toolbar height.
    private func stepToolbar() {
        stopToolbarSlide()
        toolbarParks = false
        toolbar.alphaValue = 1
        // invalidate: the toolbar row's height in the layout changed (`toolbarRowHeight`).
        needsLayout = true
        let toggle = toolbarToggles
        Motion.overlays.animateTimed(isToolbarHidden ? .disappear : .appear, in: self, {
            self.syncHeaderBand(animated: true)
            // sync-layout: inside the animation group, so the rows' frames animate to the new toolbar height.
            self.layoutSubtreeIfNeeded()
        }, completion: { [weak self] in self?.landToolbarToggle(toggle) })
    }

    /// The render server moves the rows: the next layout places them at rest and starts the slide.
    private func slideToolbar() {
        // A strip pinned to the band is the pane's and cannot follow the slide: with the band
        // open, and outside a window, every row lands in one frame.
        let slides = window != nil && (headerBand.height?.constant ?? 0) == 0
        // The frames of the last layout and the row's opacity before this change; two changes
        // before one layout start from the frames the first one found.
        let found = pendingToolbarSlide ?? ToolbarSlide(self)
        toolbarParks = true
        toolbar.alphaValue = isToolbarHidden ? 0 : 1
        syncHeaderBand(animated: false)
        // invalidate: the rows move (`toolbarRowHeight`, the parked row); that one layout starts the slide.
        needsLayout = true
        guard slides else {
            stopToolbarSlide()
            landToolbarToggle(toolbarToggles)
            return
        }
        pendingToolbarSlide = found
    }

    /// Ends a slide in flight where its rows rest; its landing no longer owns the row.
    private func stopToolbarSlide() {
        pendingToolbarSlide = nil
        pageGutter.isHidden = true
        for layer in subviews.compactMap(\.layer) { RenderSpring.stop(layer, RenderSpringKey<CGFloat>.positionY.path) }
        if let layer = toolbar.layer { RenderSpring.stop(layer, RenderSpringKey<CGFloat>.opacity.path) }
    }

    /// Called at the end of `layout()`: the rows are at rest, so each one that moved springs
    /// from where it showed, and the row fades, in one group (the gate decides what animates).
    func startToolbarSlide() {
        guard let slide = pendingToolbarSlide else { return }
        pendingToolbarSlide = nil
        var moves: [RenderSpring.Move] = []
        var pageSlides = false
        // A resize in the same turn (the pane moved, a window came back) is no slide: the rows land.
        let rows = slide.size == bounds.size ? toolbarSlideRows : []
        for view in rows {
            guard let layer = view.layer, let old = slide.frames[ObjectIdentifier(view)] else { continue }
            let shift = Self.rowShift(from: old, to: view.frame, flipped: isFlipped)
            guard shift != 0 else { continue }
            let y = layer.position.y
            moves.append(RenderSpring.Move(layer, RenderSpringKey<CGFloat>.positionY, from: y + shift, to: y))
            if view === contentContainer { pageSlides = true }
        }
        if let layer = toolbar.layer, slide.opacity != toolbar.alphaValue {
            moves.append(RenderSpring.Move(layer, RenderSpringKey<CGFloat>.opacity, from: slide.opacity, to: toolbar.alphaValue))
        }
        // The page's background under the sliding page; a see-through page (nil) shows what it shows anyway.
        if pageSlides, let color = tab.pageBackgroundColor {
            pageGutter.layer?.backgroundColor = color
            pageGutter.isHidden = false
        }
        let toggle = toolbarToggles
        Motion.overlays.renderSpring(isToolbarHidden ? .disappear : .appear).animateGroup(moves, in: self) { [weak self] _ in
            // A newer change owns the row (`toolbarToggles`), whether or not this one finished.
            self?.landToolbarToggle(toggle)
        }
    }

    /// The views a slide moves: every shown row but the gutter. A page in its own window follows
    /// the page host's frame, not its layer, so the host and the views over the page stay at rest,
    /// where `updateOcclusion` cut them out of the page window.
    var toolbarSlideRows: [NSView] {
        var overPage: [NSView] = []
        if tab.presentation == .childWindow { overPage = [contentContainer, findBar, promptBar] + pageStatus.shown }
        let resting = Set(overPage.map { ObjectIdentifier($0) })
        return subviews.filter { !$0.isHidden && $0 !== pageGutter && !resting.contains(ObjectIdentifier($0)) }
    }

    /// The `position.y` offset that shows a row where it was: a row that kept its height moves
    /// whole; one that resized (the page area) keeps its top edge, where page content is anchored.
    static func rowShift(from old: CGRect, to new: CGRect, flipped: Bool) -> CGFloat {
        (old.height == new.height || flipped) ? old.minY - new.minY : old.maxY - new.maxY
    }

    /// The landing of change number `toggle`: the gutter goes, and a hidden row stops drawing.
    func landToolbarToggle(_ toggle: Int) {
        guard toggle == toolbarToggles else { return }
        pageGutter.isHidden = true
        guard isToolbarHidden else { return }
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
