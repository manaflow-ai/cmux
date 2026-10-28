import AppKit
public import CmuxNextCompat
public import CmuxNextDesign

// The strip's side of the app's hover cards (HoverCardCoordinator); its targets
// (tabs and group chips) are hit-tested in `TabHoverCardController+Targets.swift`.
extension TabStripView {
    /// The coordinator this strip reports to (the App injects the app's one).
    public var hoverCards: HoverCardCoordinator {
        get { hoverCard.coordinator }
        set { hoverCard.coordinator = newValue }
    }

    /// Makes the strip report to `coordinator` (the App's one), registers its hover card's thumbnails (pixels in `thumbnailPages`)
    /// and samples, one memory consumer, with `memory`, and has its tab cards ask `energy` (nil: none).
    public func attachHoverCards(_ coordinator: HoverCardCoordinator, memory: any MemoryConsumerRegistry, thumbnailPages: PurgeableAllocator = .resident, energy: (any TabEnergySource)? = nil) {
        (hoverCards, hoverCard.energy) = (coordinator, energy)
        hoverCard.thumbnails = TabThumbnailCache(allocator: thumbnailPages)
        registerHoverCardMemory(with: memory)
    }

    /// Registers the hover card's thumbnails and samples, one memory consumer, with `registry`. The strip keeps the
    /// registration, so the consumer leaves the registry with the strip; a second call replaces the first.
    func registerHoverCardMemory(with registry: any MemoryConsumerRegistry) {
        hoverCard.memoryRegistration?.cancel()
        hoverCard.memoryRegistration = MemoryConsumerRegistration(
            name: TabHoverCardController.memoryConsumerName, traits: TabHoverCardController.memoryTraits,
            consumer: hoverCard, registry: registry)
    }

    /// Content moved under a possibly still pointer (layout, scroll,
    /// animation frame, the pane moved in its window): hover follows what
    /// is under the pointer now, and the coordinator re-hit-tests. Outside
    /// the visible strip (its visible rect can pass its bounds) is an exit (cx-3wu5).
    func geometryDidChange() {
        guard let window else { return }
        let point = convert(window.convertPoint(fromScreen: hoverCards.currentPointer()), from: nil)
        let lit = buttonReveal.pointerInStrip || hoveredID != nil || groups.hoveredChip != nil
        let inside = bounds.intersection(visibleRect).contains(point) && isShownInWindow
        if inside {
            if lit { updateHover(at: point, moved: false) }
        } else if lit || newTabButton.isHovered || closingModeWidth != nil { pointerLeft() }
        // A strip away from the pointer, with no card of its own, changes no card: no window
        // hit test for it (a tab switch or a strip animation elsewhere in the window).
        guard inside || lit || hoverCard.isVisible else { return }
        hoverCards.geometryChanged(in: window)
    }

    /// The pane holding this strip moved in its window (column scroll,
    /// split resize): see `geometryDidChange`.
    public func paneMovedInWindow() {
        geometryDidChange()
    }

    func clearHover() {
        setHovered(nil)
        setHoveredChip(nil)
        if let closeHoveredID { cells[closeHoveredID]?.isCloseHovered = false }
        closeHoveredID = nil
        setAudioHovered(nil)
    }
}
