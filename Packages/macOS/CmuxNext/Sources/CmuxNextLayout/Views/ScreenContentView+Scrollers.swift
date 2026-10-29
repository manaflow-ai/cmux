import AppKit
import CmuxNextDesign

/// One of the strip's nested scrollers: a row column or a scroll area.
typealias NestedScroller = ScrollerPanContainerView.Scroller

/// Rows and scroll areas pan by translation (behind `motion.renderServer`), as the strip
/// does (`ScreenContentView+StripPan.swift`). Each strip column whose rows overflow and
/// each scroll area of the strip has a motion container (`ScrollerPanContainerView`) that holds its hosts
/// and dividers, and a chrome plane that holds their rings and dims. A trackpad pan event of the scroller
/// sets the translation of the two layers and nothing else: no host, divider or ring frame, no layout, no
/// tracking area. The views stay laid out at the offset the pan started from (the scroller's `panBase`)
/// until the gesture ends, when they are laid out once at the offset the fling springs to, and the fling
/// is a render-server spring of the container's translation from where they show, with the release
/// velocity (``startScrollerFling(_:)``). Pointer input lands a scroller that shows moved first
/// (``landStripWhereItShows()``), so AppKit's hit test and `convert` read frames that agree with what
/// shows. Chrome gives every nested scroller its own scroll transform node and moves it per input event
/// (`cc/trees/transform_node.h` `scroll_offset`, `cc/input/threaded_input_handler.cc`), and flings it as
/// a compositor animation (`cc/input/scroll_offset_animations_impl.h`).
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
    /// holds nothing (``pruneScrollerContainers()``): a zoom keeps its hosts where they are. An area's
    /// container changes parent when its column's rows start or stop overflowing, keeping the window's
    /// first responder (``move(_:to:)``).
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
            if container.superview !== view { move(container, to: view) }
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

    /// The pane a zoom shows over the screen: the one zooming in or back, else the zoomed layout's one pane.
    var zoomShownPane: PaneID? { zoomMotion.pane ?? (zoomed ? paneFrames.keys.first : nil) }

    /// Places each container in a layout pass, with the strip laid out at `strip`: a row's over its parent's
    /// bounds, an area's over its window as laid out, clipping there except during a zoom (the zoomed layout
    /// has no area, and the zooming pane grows past it). During a zoom, an area's container that holds the
    /// zooming or zoomed pane's host is over its parent's bounds, as a row's is: AppKit stops hit tests,
    /// visible rects, tracking areas and cursor rects at a view's frame, whatever its layer draws. Then the
    /// translation from where the views are laid out to where the scroller shows (zero once no pan holds a
    /// base); a fling on the render server owns it until it lands.
    /// Returns true when a frame, clip or translation changed.
    func placeScrollerContainers(strip: CGFloat) -> Bool {
        guard !scrollerContainers.isEmpty else { return false }
        var changed = false, clipsChanged = false
        let clips = zoomMotion.pane == nil && !zoomed
        let zoomHost = clips ? nil : zoomShownPane.flatMap { context.hosts[$0] }
        for (scroller, container) in scrollerContainers {
            let translation: CGVector
            switch scroller {
            case let .row(column):
                if let parent = container.superview, container.place(parent.bounds) { changed = true }
                let scroll = rowScrolls[column]
                translation = CGVector(dx: 0, dy: (scroll?.laidOutOffset ?? 0) - (scroll?.state.spring.value ?? 0))
            case let .area(id):
                let holdsZoom = zoomHost.map { $0.superview === container } ?? false
                let rect = holdsZoom ? container.superview?.bounds : laidOutAreaWindow(id, strip: strip)
                if let rect, container.place(rect) { changed = true }
                container.setClips(clips)
                let scroll = areaScrolls[id]
                let placed = ScrollerPanContainerView.PlacedClip(size: container.frame.size, offset: scroll?.laidOutOffset ?? 0, clips: clips)
                if container.placedClip != placed {
                    container.placedClip = placed
                    clipsChanged = true
                }
                translation = CGVector(dx: (scroll?.laidOutOffset ?? 0) - (scroll?.state.spring.value ?? 0), dy: 0)
            }
            if container.fling == nil, container.translation != translation {
                container.setTranslation(translation)
                changed = true
            }
        }
        // A page in an area's pane re-reads its clip shape, which carries the container's clip, when the
        // clip moved against its hosts (the strip or the row moving both changes nothing for it).
        if clipsChanged { context.stripClipsDidChange() }
        return changed || clipsChanged
    }

    // MARK: Landing

    /// Whether the strip or one of its nested scrollers shows away from where its views are laid out.
    var showsPanMoved: Bool {
        stripContainer.showsMoved || scrollerContainers.values.contains { $0.showsMoved }
    }

    /// A fling of the strip, a row column or a scroll area runs on the render server.
    var panFlingsInFlight: Bool {
        stripContainer.fling != nil || scrollerContainers.values.contains { $0.fling != nil }
    }

    /// Takes every row and scroll area fling back from the render server where it shows
    /// (``takeScrollerFromServer(_:)``), and drops every pan base: the next layout pass lays them out
    /// where they show.
    func landScrollerPans() {
        takeScrollersFromServer()
        for (id, scroll) in rowScrolls where scroll.panBase != nil { rowScrolls[id]?.panBase = nil }
        for (id, scroll) in areaScrolls where scroll.panBase != nil { areaScrolls[id]?.panBase = nil }
    }

    // MARK: The fling

    /// Ends a pan of `scroller` on its container at the gesture's end with a fling on the render server,
    /// as ``startPanFling()`` does for the strip: the scroller's spring rests on the fling's target, its
    /// views lay out there once, and the translation of its container and its rings' plane springs from
    /// where it shows to zero with the release velocity. No view frame is set on the fling's frames.
    /// Returns false, changing nothing, when the pan was not on the container or the spring would not
    /// animate here; the CPU steps it then.
    func startScrollerFling(_ scroller: NestedScroller) -> Bool {
        guard let container = scrollerContainer(scroller), scrollersPanOnContainers else { return false }
        let spring = Motion.panes.renderSpring(.scroll)
        guard spring.animates(container.axisKeyPath, in: container) else { return false }
        let released: SpringValue, base: CGFloat
        switch scroller {
        case let .row(column):
            guard var scroll = rowScrolls[column], let panBase = scroll.panBase else { return false }
            released = scroll.state.spring
            base = panBase
            scroll.state.spring.snap()
            scroll.panBase = nil
            rowScrolls[column] = scroll
        case let .area(id):
            guard var scroll = areaScrolls[id], let panBase = scroll.panBase else { return false }
            released = scroll.state.spring
            base = panBase
            scroll.state.spring.snap()
            scroll.panBase = nil
            areaScrolls[id] = scroll
        }
        // A view at `p` laid out at offset `base` shows at `p - base + translation`; laid out at the target
        // it is at `p - target`, so it shows `translation + target - base` away from there.
        let displacement = container.alongAxis(container.translation) + released.target - base
        // The fling first: the layout pass below then leaves the translation to it.
        container.startFling(from: displacement, velocity: -released.velocity, spring: spring) { [weak self] in
            self?.panFlingLanded(strip: false)
        }
        refreshRowShift()
        applyPresentation()
        return true
    }

    /// Takes `scroller`'s fling back from the render server where it shows, with its velocity: its spring
    /// goes on from there toward the same target on the CPU. Its views stay laid out where the fling
    /// started, held by the container's translation, until the next layout pass places them at the spring.
    func takeScrollerFromServer(_ scroller: NestedScroller) {
        guard let container = scrollerContainers[scroller], container.fling != nil else { return }
        let shown = container.stopFling()
        let moved = container.alongAxis(shown.translation), velocity = container.alongAxis(shown.velocity)
        switch scroller {
        case let .row(column):
            guard var scroll = rowScrolls[column] else { return container.setTranslation(.zero) }
            scroll.state.spring.value = scroll.laidOutOffset - moved
            scroll.state.spring.velocity = -velocity
            scroll.panBase = scroll.laidOutOffset
            rowScrolls[column] = scroll
        case let .area(id):
            guard var scroll = areaScrolls[id] else { return container.setTranslation(.zero) }
            scroll.state.spring.value = scroll.laidOutOffset - moved
            scroll.state.spring.velocity = -velocity
            scroll.panBase = scroll.laidOutOffset
            areaScrolls[id] = scroll
        }
        refreshRowShift()
        context.requestFrames()
    }

    /// Takes every row and scroll area fling back from the render server (``takeScrollerFromServer(_:)``).
    func takeScrollersFromServer() {
        for (scroller, container) in scrollerContainers where container.fling != nil { takeScrollerFromServer(scroller) }
    }

    /// Whether `scroller`'s reducer has to leave a fling on the render server before `reduce` runs: it
    /// moves the spring the fling rests on. An event that leaves it where it rests (a focus sync that
    /// reveals the row the fling lands on) lets the fling go on, as the strip's `reduceCamera` does.
    func scrollerFlingYields(_ scroller: NestedScroller, to reduce: (inout ColumnScrollState) -> Void) -> Bool {
        guard scrollerContainers[scroller]?.fling != nil else { return false }
        let current: ColumnScrollState? = switch scroller {
        case let .row(column): rowScrolls[column]?.state
        case let .area(id): areaScrolls[id]?.state
        }
        guard var probe = current else { return false }
        reduce(&probe)
        return probe.spring != current?.spring
    }

    /// How far the row and scroll area flings on the render server that carry `pane` still move it, along each
    /// axis, from where they rest (each container's model translation is its rest during a fling): what shows now,
    /// its velocity and its overshoot (``SpringParameters/excursion(displacement:velocity:)``). Nil when none carries
    /// it. The visibility pass sweeps the pane over it (``displayedSweeps()``), as it sweeps the strip's viewport
    /// over the strip's fling.
    func scrollerFlingReach(of pane: PaneID) -> (x: Excursion, y: Excursion)? {
        guard let host = context.hosts[pane] else { return nil }
        var x = Excursion.zero, y = Excursion.zero, flings = false
        var current = host.superview
        while let container = current as? ScrollerPanContainerView {
            if let fling = container.fling {
                flings = true
                let shown = container.shown
                let reach = fling.spring.excursion(displacement: container.alongAxis(shown.translation) - container.alongAxis(container.translation),
                                                   velocity: container.alongAxis(shown.velocity))
                if container.scroller.isArea { x.add(reach) } else { y.add(reach) }
            }
            current = container.superview
        }
        return flings ? (x, y) : nil
    }
}
