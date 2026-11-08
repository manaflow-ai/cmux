import AppKit
import CmuxNextDesign

/// The pointer over a screen: one tracking area on the screen view, which does not move, hit-tests the current frames
/// for the dividers' hover and resize cursor (`ScreenDividers.refreshHover`) and for the pane content's moves, hover and
/// cursor (``PanePointerFollowing``: a terminal, a tab strip), as Chrome sets the cursor from the hit test of each mouse
/// event. The handles and that content have no tracking areas and no cursor rects: AppKit moves those with a view's
/// frame, and each move rebuilt the window's structural regions (drag margins and a constraint min-size walk of every
/// view, every tracking area) in that display cycle, while a spring or a drag moves panes in every frame (HOT PATH AUDIT
/// frames, DividerCursorNoRegionRebuildTests; RESIZE MAIN BUDGET, PaneMotionPointerAreasTests). This object owns that
/// tracking area, so its events come here and never mix with the screen's responder chain (a subview's move passed up
/// to the layout root's pane hover).
@MainActor
final class ScreenDividerPointer: NSResponder {
    private weak var screen: ScreenContentView?
    private var trackingArea: NSTrackingArea?
    /// The resize cursor this screen set last (its hover, or a handle's `cursorUpdate`); nil while it shows none.
    private(set) var shownCursor: NSCursor?
    /// The pane content under the pointer (the last hit test's), which heard it come in; nil over none.
    private(set) weak var contentTarget: (any PanePointerFollowing)?
    /// Whether the cursor shown now is pane content's: leaving it for content that sets none gives the cursor back.
    private var showsContentCursor = false

    private struct Region {
        weak var region: (any PanePointerRegion)?
        var inside: Bool
    }

    /// The regions of the pane content in this screen (``PanePointerRegion``), with whether the pointer was in each.
    private var regions: [ObjectIdentifier: Region] = [:]

    /// `region` hears the pointer from now on, starting from where the pointer is now (an exit must follow an inside).
    func addRegion(_ region: any PanePointerRegion) {
        regions = regions.filter { $0.value.region != nil }
        guard regions[ObjectIdentifier(region)] == nil else { return }
        let inside = screen?.window.map { contains(region, $0.mouseLocationOutsideOfEventStream) } ?? false
        regions[ObjectIdentifier(region)] = Region(region: region, inside: inside)
        region.panePointerInside(inside)
    }

    func removeRegion(_ region: any PanePointerRegion) {
        regions[ObjectIdentifier(region)] = nil
    }

    /// A handle answered AppKit's `cursorUpdate` with its resize cursor: the screen gives it back when the pointer
    /// leaves the dividers or the screen hides, as for its own.
    func handleDidShow(_ cursor: NSCursor) { shownCursor = cursor }

    init(screen: ScreenContentView) {
        self.screen = screen
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The screen's tracking areas are being rebuilt (`updateTrackingAreas`): one area over its visible rect.
    func installTrackingArea(in view: NSView) {
        if let trackingArea { view.removeTrackingArea(trackingArea) }
        // Always active: pane content follows the pointer in a window that is not key (a terminal's mouse reports, its
        // link hover), as its own area did; the dividers' hover still asks for the key window (`hoverPointer`).
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self)
        view.addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { refresh(event, windowsChanged: true) }
    override func mouseExited(with event: NSEvent) { refresh(event, windowsChanged: true, left: true) }
    override func mouseMoved(with event: NSEvent) { refresh(event, windowsChanged: false) }

    private func refresh(_ event: NSEvent, windowsChanged: Bool, left: Bool = false) {
        guard let screen else { return }
        // Where it entered or left, the windows over the pointer may differ: the window server is asked again.
        if windowsChanged { screen.context.invalidateHoverTopmost() }
        ScreenDividers(screen: screen).refreshHover(event: event)
        follow(event, in: screen, left: left)
    }

    /// The pane content under the pointer hears it come in, move and leave, and shows its cursor unless a divider shows
    /// its resize cursor there. A pointer that leaves the content for a view that sets its own cursor gets the arrow
    /// and that view's cursor rects again, once (as `show(nil...)` does for a handle).
    private func follow(_ event: NSEvent, in screen: ScreenContentView, left: Bool) {
        let target = left ? nil : Self.content(at: event.locationInWindow, in: screen)
        if target !== contentTarget {
            contentTarget?.panePointerExited(with: event)
            contentTarget = target
            target?.panePointerEntered(with: event)
        } else {
            target?.panePointerMoved(with: event)
        }
        followRegions(event.locationInWindow, left: left)
        guard shownCursor == nil else { return }
        if let target, let cursor = target.panePointerCursor(at: target.convert(event.locationInWindow, from: nil)) {
            cursor.set()
            showsContentCursor = true
        } else if showsContentCursor {
            showsContentCursor = false
            giveCursorBack(in: screen, pointer: event.locationInWindow, event: event)
        }
    }

    /// Each region hears the pointer come in or leave, from its current geometry (a pointer outside the screen is in none).
    private func followRegions(_ windowPoint: NSPoint, left: Bool) {
        for (key, entry) in regions {
            guard let region = entry.region else {
                regions[key] = nil
                continue
            }
            let inside = !left && contains(region, windowPoint)
            guard inside != entry.inside else { continue }
            regions[key]?.inside = inside
            region.panePointerInside(inside)
        }
    }

    /// Whether `windowPoint` is in `region` now (its view shown in this screen's window).
    private func contains(_ region: any PanePointerRegion, _ windowPoint: NSPoint) -> Bool {
        guard let place = region.panePointerRegion, place.view.window === screen?.window, !place.view.isHiddenOrHasHiddenAncestor
        else { return false }
        return place.rect.contains(place.view.convert(windowPoint, from: nil))
    }

    /// The innermost ``PanePointerFollowing`` view at `windowPoint` inside `screen` (the window's own hit test).
    static func content(at windowPoint: NSPoint, in screen: ScreenContentView) -> (any PanePointerFollowing)? {
        guard let frameView = screen.window?.contentView?.superview,
              let hit = frameView.hitTest(frameView.convert(windowPoint, from: nil)) else { return nil }
        var view: NSView? = hit
        while let current = view, current !== screen {
            if let target = current as? any PanePointerFollowing { return target }
            view = current.superview
        }
        return nil
    }

    /// Shows `handle`'s resize cursor, or gives the cursor back when the pointer left the last one. With no event (the
    /// handles moved under a still pointer) only a change sets it; a pointer event sets it every time, after whatever
    /// AppKit's cursor rects of the views around set for the same move. `pointer` (window coordinates) is the one the
    /// hover hit test read (the real pointer, or `debug.mouse`'s).
    func show(_ handle: DividerHandleView?, in screen: NSView, pointer: NSPoint?, event: NSEvent?) {
        if let handle {
            let cursor = handle.resizeCursor
            guard event != nil || shownCursor != cursor else { return }
            cursor.set()
            shownCursor = cursor
            return
        }
        guard shownCursor != nil else { return }
        shownCursor = nil
        giveCursorBack(in: screen, pointer: pointer, event: event)
    }

    /// The arrow, then the view under the pointer shows its own cursor again: pane content its own (``follow``), any
    /// other view through AppKit's cursor rects, read again for this one change.
    private func giveCursorBack(in screen: NSView, pointer: NSPoint?, event: NSEvent?) {
        NSCursor.arrow.set()
        guard let window = screen.window, let content = window.contentView else { return }
        let point = event?.locationInWindow ?? pointer ?? window.mouseLocationOutsideOfEventStream
        guard let hit = content.hitTest(content.superview?.convert(point, from: nil) ?? point), hit !== screen,
              !(hit is DividerHandleView) else { return }
        if let content = contentTarget, hit === content || hit.isDescendant(of: content),
           let cursor = content.panePointerCursor(at: content.convert(point, from: nil)) {
            cursor.set()
            showsContentCursor = true
            return
        }
        window.invalidateCursorRects(for: hit)
    }
}

/// The screen's one tracking area serves the pane content inside it (``PanePointerFollowing``, ``PanePointerRegion``).
extension ScreenContentView: PanePointerArea {
    func addPointerRegion(_ region: any PanePointerRegion) { dividerPointer.addRegion(region) }
    func removePointerRegion(_ region: any PanePointerRegion) { dividerPointer.removeRegion(region) }
}

extension ScreenContentView {
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        dividerPointer.installTrackingArea(in: self)
    }

    /// Hidden (itself or an ancestor: a workspace switch): it gets no pointer events now, so it gives its cursor back.
    override func viewDidHide() {
        super.viewDidHide()
        refreshDividerHover()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { dividerPointer.show(nil, in: self, pointer: nil, event: nil) }
        super.viewWillMove(toWindow: newWindow)
    }

    /// In a window: the divider tracking area goes on at once. AppKit calls `updateTrackingAreas` when tracking areas
    /// need recomputing, not for a view that has none yet (px-divider-hover: the pointer on a divider got no event).
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { dividerPointer.installTrackingArea(in: self) }
    }
}
