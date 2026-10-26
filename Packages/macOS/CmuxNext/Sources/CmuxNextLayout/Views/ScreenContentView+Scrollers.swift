import AppKit
import CmuxNextDesign

/// One of the strip's nested scrollers: a row column or a scroll area.
typealias NestedScroller = ScrollerPanContainerView.Scroller

/// Rows and scroll areas pan by translation (p04-input-050, behind `motion.renderServer`), as the strip
/// does (p03-rendering-026, `ScreenContentView+StripPan.swift`). Each strip column whose rows overflow and
/// each scroll area of the strip has a motion container (`ScrollerPanContainerView`) that holds its hosts
/// and dividers, and a chrome plane that holds their rings and dims. A trackpad pan event of the scroller
/// sets the translation of the two layers and nothing else: no host, divider or ring frame, no layout, no
/// tracking area. The views stay laid out at the offset the pan started from (the scroller's `panBase`)
/// until the gesture ends, when they are laid out once where the rows show and the fling moves them on the
/// CPU. Pointer input lands a scroller that shows moved first (``landStripWhereItShows()``), so AppKit's
/// hit test and `convert` read frames that agree with what shows. Chrome gives every nested scroller its
/// own scroll transform node and moves it per input event (`cc/trees/transform_node.h` `scroll_offset`,
/// `cc/input/threaded_input_handler.cc`).
extension ScreenContentView {
    // MARK: Containers

    /// The nested scrollers that get a container now, each with the scroller whose container holds it
    /// (nil: the strip container): every strip column whose rows overflow, then every scroll area of the
    /// strip, inside its row's container when its column's rows overflow. None without the strip's
    /// dividers in its container (``dividersInStripContainer``: `motion.renderServer` off, a canvas), and
    /// none for a docked column, whose hosts sit in this view.
    private func scrollerPlan() -> [(scroller: NestedScroller, parent: NestedScroller?)] {
        guard dividersInStripContainer else { return [] }
        let docked = Set(baseGeometry.dock.map(\.column))
        let rows = Set(baseGeometry.rowStacks.compactMap { id, stack in stack.scrolls && !docked.contains(id) ? id : nil })
        var plan = rows.map { (scroller: NestedScroller.row($0), parent: NestedScroller?.none) }
        for (id, area) in baseGeometry.scrollAreas {
            guard let pane = area.panes.first, baseGeometry.scrolls(pane: pane) else { continue }
            let row = baseGeometry.rowColumnOfPane[pane].flatMap { rows.contains($0) ? NestedScroller.row($0) : nil }
            plan.append((scroller: .area(id), parent: row))
        }
        return plan
    }

    /// Makes the containers the layout needs and puts each in its parent (``scrollerPlan()``), before the
    /// hosts are placed (`reconcile`, ``ensureStacking()``). One the layout no longer needs stays until it
    /// holds nothing (``pruneScrollerContainers()``): a zoom keeps its hosts where they are.
    func reconcileScrollerContainers() {
        let plan = scrollerPlan()
        wantedScrollers = Set(plan.map { $0.scroller })
        for entry in plan where scrollerContainers[entry.scroller] == nil {
            let container = ScrollerPanContainerView(scroller: entry.scroller)
            container.onShowsMovedChange = { [weak self] in self?.context.stripMovedDidChange() }
            scrollerContainers[entry.scroller] = container
        }
        for entry in plan {
            guard let container = scrollerContainers[entry.scroller] else { continue }
            let parent = entry.parent.flatMap { scrollerContainers[$0] }
            let view: NSView = parent ?? stripContainer
            let plane: NSView = parent?.chromePlane ?? stripChrome
            if container.superview !== view { view.addSubview(container) }
            if container.chromePlane.superview !== plane { plane.addSubview(container.chromePlane) }
        }
    }

    /// Removes the containers the layout no longer needs once they hold nothing (areas first: one may sit
    /// in a row's container). The rings left in their planes go back with the next overlay sync.
    func pruneScrollerContainers() {
        let unused = scrollerContainers.filter { !wantedScrollers.contains($0.key) }
        for (scroller, container) in unused.sorted(by: { $0.key.isArea && !$1.key.isArea }) where container.subviews.isEmpty {
            container.removeFromSuperview()
            container.chromePlane.removeFromSuperview()
            scrollerContainers[scroller] = nil
        }
    }

    /// The container of `scroller` while the layout gives it one.
    func scrollerContainer(_ scroller: NestedScroller) -> ScrollerPanContainerView? {
        wantedScrollers.contains(scroller) ? scrollerContainers[scroller] : nil
    }

    /// Where `pane`'s host sits in the strip: its scroll area's container, else its row's, else nil (the
    /// strip container).
    func scrollerContainer(of pane: PaneID) -> ScrollerPanContainerView? {
        if let area = baseGeometry.scrollAreaOfPane[pane], let container = scrollerContainer(.area(area)) { return container }
        return baseGeometry.rowColumnOfPane[pane].flatMap { scrollerContainer(.row($0)) }
    }

    /// Where the divider `kind` sits in the strip: the container of the scroller that moves it (the offsets
    /// of ``rowOffset(of:)`` and ``areaOffset(of:)``), else nil (the strip container).
    func scrollerContainer(of kind: DividerHandleView.Kind) -> ScrollerPanContainerView? {
        switch kind {
        case .columnEdge: return nil
        case let .rowEdge(column, _): return scrollerContainer(.row(column))
        case let .split(id):
            if let area = baseGeometry.scrollAreaOfSplit[id], let container = scrollerContainer(.area(area)) { return container }
            return baseGeometry.rowColumnOfSplit[id].flatMap { scrollerContainer(.row($0)) }
        }
    }

    /// The plane `host`'s ring and dim sit in while the strip's rings have their own (`StripChromePlane`):
    /// the plane of the container that holds it, the strip's for a host in the strip container; nil for a
    /// host in this view.
    func chromePlane(for host: PaneHostView) -> StripChromePlane? {
        if host.superview === stripContainer { return stripChrome }
        return (host.superview as? ScrollerPanContainerView)?.chromePlane
    }

    /// Sizes each container's chrome plane to its parent plane, rows first, so a ring's frame there is in the
    /// layout root's coordinates (`LayoutRootView.syncOverlay`, after it placed the strip's plane).
    func placeScrollerChromePlanes() {
        let ordered = scrollerContainers.values.sorted { !$0.scroller.isArea && $1.scroller.isArea }
        for container in ordered {
            let plane = container.chromePlane
            if let parent = plane.superview, plane.frame != parent.bounds { plane.frame = parent.bounds }
        }
    }

    /// `view`'s place in this view, less its frame: the translations of the pan containers above it.
    func panTranslation(of view: NSView) -> CGVector {
        var moved = CGVector.zero
        var current = view.superview
        while let container = current as? any PanMotionContainer {
            moved.dx += container.panTranslation.dx
            moved.dy += container.panTranslation.dy
            current = container.superview
        }
        return moved
    }

    /// The translation `view` shows now: ``panTranslation(of:)`` with a strip fling's shown translation.
    func shownPanTranslation(of view: NSView) -> CGVector {
        var moved = CGVector.zero
        var current = view.superview
        while let container = current as? any PanMotionContainer {
            moved.dx += container.shownPanTranslation.dx
            moved.dy += container.shownPanTranslation.dy
            current = container.superview
        }
        return moved
    }

    // MARK: The pan

    /// A nested scroller can pan on its container: its container is in the layout and nothing reads the
    /// strip's geometry from frames while it shows moved. Not beside a docked column (the rings' dock
    /// covers stay where the dock is), during a zoom (it lifts the containers), with floating panes (the
    /// window's shade cuts the cards from frames) or with content in child windows (a Chromium page window
    /// is placed from its host's frame): the conditions of the strip's pan (``pansOnContainer``).
    var scrollersPanOnContainers: Bool {
        stripDividersInContainer && baseGeometry.dock.isEmpty && zoomMotion.pane == nil && !zoomed && !stripContainer.isLifted
            && !context.style.floatingPanes && !context.childWindowContentShows()
    }

    /// Shows a trackpad pan event of `scroller` on its container: its translation (and its rings' plane's)
    /// moves to the offset the scroller's reducer presents; the pan's first event takes the offset the
    /// views are laid out at as its base. No layout, no overlay sync, no display frame.
    /// Returns false when the container cannot carry it (``scrollersPanOnContainers``).
    func presentScrollerPan(_ scroller: NestedScroller) -> Bool { // perf-hot: 0.3ms motion-frame
        guard let container = scrollerContainer(scroller), scrollersPanOnContainers else { return false }
        let translation: CGVector
        switch scroller {
        case let .row(column):
            guard var scroll = rowScrolls[column] else { return false }
            let base = scroll.panBase ?? scroll.laidOutOffset
            if scroll.panBase == nil {
                scroll.panBase = base
                rowScrolls[column] = scroll
            }
            // Laid out at y - base, shown at y - offset.
            translation = CGVector(dx: 0, dy: base - scroll.state.spring.value)
        case let .area(id):
            guard var scroll = areaScrolls[id] else { return false }
            let base = scroll.panBase ?? scroll.laidOutOffset
            if scroll.panBase == nil {
                scroll.panBase = base
                areaScrolls[id] = scroll
            }
            translation = CGVector(dx: base - scroll.state.spring.value, dy: 0)
        }
        container.setTranslation(translation)
        if !userMotionActive {
            userMotionActive = true
            context.userMotionStepped()
        }
        return true
    }

    /// Before a layout pass: a pan base stays only while its finger is down and the container still
    /// carries it; each scroller records the offset the pass lays its views out at.
    func prepareScrollerLayout() {
        var carries: Bool?
        func keeps(_ scroller: NestedScroller, gesturing: Bool) -> Bool {
            guard gesturing, scrollerContainer(scroller) != nil else { return false }
            if carries == nil { carries = scrollersPanOnContainers }
            return carries ?? false
        }
        for (id, scroll) in rowScrolls {
            let base = scroll.panBase != nil && keeps(.row(id), gesturing: scroll.state.isGestureActive) ? scroll.panBase : nil
            let laidOut = base ?? scroll.state.spring.value
            guard base != scroll.panBase || laidOut != scroll.laidOutOffset else { continue }
            rowScrolls[id]?.panBase = base
            rowScrolls[id]?.laidOutOffset = laidOut
        }
        for (id, scroll) in areaScrolls {
            let base = scroll.panBase != nil && keeps(.area(id), gesturing: scroll.state.isGestureActive) ? scroll.panBase : nil
            let laidOut = base ?? scroll.state.spring.value
            guard base != scroll.panBase || laidOut != scroll.laidOutOffset else { continue }
            areaScrolls[id]?.panBase = base
            areaScrolls[id]?.laidOutOffset = laidOut
        }
    }

    /// Places each container in a layout pass, with the strip laid out at `strip`: a row's over the strip
    /// container's bounds, an area's over its window as laid out, clipping there except during a zoom (the
    /// zoomed layout has no area, and the zooming pane grows past it); and the translation from where the
    /// views are laid out to where the scroller shows (zero once no pan holds a base).
    /// Returns true when a frame, clip or translation changed.
    func placeScrollerContainers(strip: CGFloat) -> Bool {
        guard !scrollerContainers.isEmpty else { return false }
        var changed = false, clipsChanged = false
        let clips = zoomMotion.pane == nil && !zoomed
        for (scroller, container) in scrollerContainers {
            let translation: CGVector
            switch scroller {
            case let .row(column):
                if let parent = container.superview, container.place(parent.bounds) { changed = true }
                let scroll = rowScrolls[column]
                translation = CGVector(dx: 0, dy: (scroll?.laidOutOffset ?? 0) - (scroll?.state.spring.value ?? 0))
            case let .area(id):
                if let window = laidOutAreaWindow(id, strip: strip), container.place(window) { clipsChanged = true }
                if container.setClips(clips) { clipsChanged = true }
                let scroll = areaScrolls[id]
                translation = CGVector(dx: (scroll?.laidOutOffset ?? 0) - (scroll?.state.spring.value ?? 0), dy: 0)
            }
            if container.translation != translation {
                container.setTranslation(translation)
                changed = true
            }
        }
        // A page in an area's pane re-reads its clip shape, which carries the container's clip.
        if clipsChanged { context.stripClipsDidChange() }
        return changed || clipsChanged
    }

    // MARK: Landing

    /// Whether the strip or one of its nested scrollers shows away from where its views are laid out.
    var showsPanMoved: Bool {
        stripContainer.showsMoved || scrollerContainers.values.contains { $0.showsMoved }
    }

    /// Drops every row and scroll area pan base: the next layout pass lays them out where they show.
    func landScrollerPans() {
        for (id, scroll) in rowScrolls where scroll.panBase != nil { rowScrolls[id]?.panBase = nil }
        for (id, scroll) in areaScrolls where scroll.panBase != nil { areaScrolls[id]?.panBase = nil }
    }
}
