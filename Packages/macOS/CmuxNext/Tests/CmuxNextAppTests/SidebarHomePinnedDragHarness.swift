import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// The sidebar as Lawrence's NIGHTLY drew it on 2026-10-30 ("i tried to drag home around and now it's stuck in this
/// state"): the list's top block holds Home alone, the Pinned block three pinned workspace rows, and a machine list
/// three workspace rows under them. The document half (`SidebarDocDrag`) takes a drop as the reducer does: beside or
/// into any row except the dragged ones, and Pinned only for what is pinned already (`keepingPinned`). It records
/// every drop it is sent instead of moving anything.
@MainActor final class SidebarHomePinnedDragHarness {
    static let home = LayoutItem(id: LayoutItemID("itm_home"), ref: SidebarLayoutDocument.homeRef)
    static let pins = ["perf", "chromium", "chief"].map { LayoutItem(id: LayoutItemID("itm_pin_\($0)"), ref: .workspace("local:ws-pin-\($0)")) }
    static let loose = ["cpu", "slack", "align"].map { WorkspaceID("ws-\($0)") }
    static let machineSection = "sec_m_local"

    let list: SidebarListView
    let window: NSWindow
    /// Every drop the document was sent: the moved items and the target.
    private(set) var drops: [([String], SidebarDocTarget)] = []
    /// Every item a press or click opened.
    private(set) var activated: [LayoutItemID] = []

    init() {
        _ = NSApplication.shared
        let top = LayoutSection(id: SidebarLayoutDocument.topSectionID, region: .top, look: .builtIn, arrangement: .list, items: [Self.home])
        let pinned = SidebarLayoutDocument.pinnedSection(items: Self.pins)
        var infos: [LayoutItemID: SidebarItemInfo] = [Self.home.id: .fallback(for: Self.home)]
        for (pin, title) in zip(Self.pins, ["cmux Performance Lead", "cmux-chromium lead", "Chief TUI + fast iteration"]) {
            var info = SidebarItemInfo(title: title, symbol: "textformat")
            info.textOnly = true
            info.workspace = WorkspaceID(pin.ref.value.replacingOccurrences(of: "local:", with: ""))
            infos[pin.id] = info
        }
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let model = SidebarModel(sections: [
            SidebarSection(kind: .custom(SidebarCustomSection(id: top.id.rawValue)), nodes: []),
            SidebarSection(kind: .custom(SidebarCustomSection(id: pinned.id.rawValue)), nodes: []),
            SidebarSection(kind: .machine(machine), nodes: Self.loose.map { .workspace(SidebarWorkspace(id: $0, title: $0.rawValue)) }),
        ])
        list = SidebarListView(model: model)
        var metrics = SidebarRegionMetrics.standard
        metrics.trailingTrim = SidebarStyle.rowTrailingTrim
        list.blocks = SidebarListBlocks(sections: [top.id.rawValue: top, pinned.id.rawValue: pinned], infos: infos, collapsed: [],
                                        look: .quiet, metrics: metrics, drawsLines: false, appHeights: [:])
        let pinnedKeys = Set(Self.pins.map(\.id.rawValue) + [SidebarDocStore.pinnedSection])
        let keys = [Self.home.id.rawValue, top.id.rawValue, Self.machineSection] + Array(pinnedKeys) + Self.loose.map { "itm_" + $0.rawValue }
        model.docDrag = SidebarDocDrag(item: { key in
            if case let .workspace(id) = key { return "itm_" + id.rawValue }
            return nil
        }, section: { id in
            if case .machine = id { return Self.machineSection }
            return nil
        }, begin: { dragged in
            let draggingPinned = dragged.allSatisfy(pinnedKeys.contains)
            var table: [String: SidebarDocAcceptance] = [:]
            for key in keys {
                if dragged.contains(key) {
                    table[key] = SidebarDocAcceptance(before: false, into: false, after: false, refusal: "self")
                } else if pinnedKeys.contains(key), !draggingPinned {
                    table[key] = SidebarDocAcceptance(before: false, into: false, after: false, refusal: "pinned_area")
                } else {
                    table[key] = SidebarDocAcceptance(before: true, into: true, after: true)
                }
            }
            return table
        }, drop: { _, _ in })
        window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 260, height: 520), styleMask: [.borderless],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 520))
        window.contentView = root
        list.frame = root.bounds
        root.addSubview(list)
        // The drop half records what it is sent (set after `self` is whole).
        model.docDrag?.drop = { [unowned self] items, target in drops.append((items, target)) }
        list.leftButtonIsDown = { false }
        list.configureBlockRegion = { [unowned self] region in region.onActivateWithModifiers = { [unowned self] id, _ in activated.append(id) } }
        window.orderFrontRegardless()
        settle()
        // The pointer is outside the window: a row's hover fill is the pointer's, and none is over a row now.
        PointerHover.setDebugPointer(nil, in: window)
    }

    func close() {
        window.close()
    }

    func settle() {
        list.reload(animated: false)
        list.layoutSubtreeIfNeeded()
        list.rowViews.values.forEach { $0.layoutSubtreeIfNeeded() }
        for region in list.blockRegions { region.itemViews.values.forEach { $0.layoutSubtreeIfNeeded(); $0.layout() } }
    }

    /// The row view that draws block item `id` now.
    func item(_ id: LayoutItemID) throws -> SidebarItemRowView {
        let view = try #require(list.blockRegions.lazy.compactMap { $0.itemView(id) }.first, "no block draws \(id.rawValue)")
        view.layoutSubtreeIfNeeded()
        return view
    }

    /// The region (block) that holds item `id`.
    func region(of id: LayoutItemID) -> SidebarRegionView? {
        list.blockRegions.first { $0.itemView(id) != nil }
    }

    /// A left mouse event of `type` at `view`'s center moved down by `down` points, in window coordinates.
    func event(_ type: NSEvent.EventType, on view: NSView, down: CGFloat = 0) throws -> NSEvent {
        let center = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        return try mouse(type, at: NSPoint(x: center.x, y: center.y - down))
    }

    /// A left mouse event of `type` at `point` (window coordinates).
    func mouse(_ type: NSEvent.EventType, at point: NSPoint) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                        pressure: type == .leftMouseUp ? 0 : 1))
    }

    /// The Escape key, as the window would send it.
    func escape() throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                                      charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
    }

    /// The drag cards (`DragLiftView`) anywhere in the window.
    var lifts: [DragLiftView] {
        var found: [DragLiftView] = []
        var stack: [NSView] = window.contentView.map { [$0] } ?? []
        while let view = stack.popLast() {
            if let lift = view as? DragLiftView { found.append(lift) }
            stack.append(contentsOf: view.subviews)
        }
        return found
    }

    /// Ends a card's flight now (its landing's completion), as the frame clock would.
    func finishFlights() {
        list.endLanding()
        settle()
    }

    /// Checks that every block item and list row is at its rest look: shown, in the window, no pressed or hover
    /// fill (the fill a fresh row of the same content draws), no tile held hidden under a press, no card.
    func expectEveryRowAtRest(_ context: String, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(list.drag == nil, "\(context): a drag is still held", sourceLocation: sourceLocation)
        #expect(lifts.isEmpty, "\(context): \(lifts.count) drag card(s) stay in the window", sourceLocation: sourceLocation)
        #expect(list.suppressed.isEmpty, "\(context): rows stay hidden under a gone card: \(list.suppressed)", sourceLocation: sourceLocation)
        for region in list.blockRegions {
            #expect(region.docPressedItem == nil, "\(context): \(region.docPressedItem?.rawValue ?? "") is held as pressed",
                    sourceLocation: sourceLocation)
            for (id, view) in region.itemViews where !id.isTransient {
                #expect(view.isDescendant(of: list), "\(context): \(id.rawValue) left the list", sourceLocation: sourceLocation)
                #expect(view.alphaValue == 1 && !view.isHiddenOrHasHiddenAncestor, "\(context): \(id.rawValue) is hidden (alpha \(view.alphaValue))",
                        sourceLocation: sourceLocation)
                #expect(!view.isHovered, "\(context): \(id.rawValue) keeps a hover", sourceLocation: sourceLocation)
                let rest = SidebarItemRowView()
                rest.configure(view.info, style: view.style)
                #expect(view.fill == rest.fill, "\(context): \(id.rawValue) keeps a pressed or hover fill (\(String(describing: view.fill)))",
                        sourceLocation: sourceLocation)
            }
        }
        for (key, view) in list.rowViews where list.displayed.row(for: key) != nil {
            #expect(view.alphaValue == 1, "\(context): row \(key) is hidden (alpha \(view.alphaValue))", sourceLocation: sourceLocation)
        }
    }
}
