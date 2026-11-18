import AppKit
import CmuxNextCompat
import CmuxNextDesign
import CmuxVisibleRows

/// The sidebar's Team section (lane D): the team's Cloud workspaces and chats under one of four
/// filters, each row with its follow (eye) toggle and a menu with Reassign To, Copy Link and
/// Archive. It draws ``CloudTeamSessionStore`` and runs every change as an action, so a click
/// does what `cmux cloud follow|reassign|copy-session-link|archive-session` does.
@MainActor
final class CloudTeamSectionView: NSView {
    /// Rows a section shows before it scrolls.
    static let maxRows = 8
    static let rowHeight: CGFloat = 26
    static let filterHeight: CGFloat = 26

    /// The section's height for the current rows (the sidebar asks before it lays out).
    static func height(for store: CloudTeamSessionStore) -> CGFloat {
        filterHeight + rowHeight * CGFloat(max(1, min(maxRows, store.sessions.count)))
    }

    /// What the section draws, read from the store in one observation.
    nonisolated struct Shown: Equatable, Sendable {
        var filter: CloudTeamSessionStore.Filter
        var sessions: [CloudTeamSession]
        var members: [CloudTeamMember]
        /// Shown in place of the rows while there are none: the list's refusal, Loading… or the filter's empty text.
        var placeholder: String
    }

    static func shown(_ store: CloudTeamSessionStore) -> Shown {
        let idle = store.isLoading ? CloudTeamStrings.loading : CloudTeamStrings.empty(store.filter)
        return Shown(filter: store.filter, sessions: store.sessions, members: store.members,
                     placeholder: store.listError?.message ?? idle)
    }

    private let store: CloudTeamSessionStore
    private let actions: CloudTeamSessionRowView.Actions
    var colors: CloudTeamColors { didSet { if colors != oldValue { recolor() } } }
    private(set) var shown: Shown
    private(set) var filters: [CloudTeamFilterButton] = []
    /// The made rows top-down: the ones in view and one viewport past each edge, never every session.
    var rows: [CloudTeamSessionRowView] { list.subviews.compactMap { $0 as? CloudTeamSessionRowView } }
    /// The made rows by session key, so a row stays with its session when others come, go or move.
    private var made: [String: CloudTeamSessionRowView] = [:]
    /// Rows scrolled out of range, for the next ones that come in.
    private var spare: [CloudTeamSessionRowView] = []
    /// The rows' work, for the visible-rows contract (`CloudTeamSectionRows`).
    let listWork = ListWorkMeter()
    private let placeholder = NSTextField(wrappingLabelWithString: "")
    let scroll = OverlayScrollView()
    private let list = CloudTeamRowList()

    init(store: CloudTeamSessionStore, colors: CloudTeamColors, actions: CloudTeamSessionRowView.Actions) {
        self.store = store
        self.actions = actions
        self.colors = colors
        shown = Self.shown(store)
        super.init(frame: .zero)
        for filter in CloudTeamSessionStore.Filter.allCases {
            let button = CloudTeamFilterButton(title: CloudTeamStrings.filterTitle(filter), colors: colors)
            button.onClick = { [weak self] in self?.select(filter) }
            filters.append(button)
            addSubview(button)
        }
        placeholder.font = Typography.caption
        placeholder.maximumNumberOfLines = 2
        placeholder.cell?.truncatesLastVisibleLine = true
        addSubview(placeholder)
        let clip = CloudTeamRowClip()
        clip.onBoundsChange = { [weak self] in self?.realize() }
        scroll.contentView = clip
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.documentView = list
        SystemScrollers.followThin(scroll)
        addSubview(scroll)
        recolor()
        apply(shown)
        watch()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    var placeholderText: String? { placeholder.isHidden ? nil : placeholder.stringValue }

    /// The filter is this view's state: the store shows the rows it has for it at once, then lists.
    func select(_ filter: CloudTeamSessionStore.Filter) {
        let store = store
        // task-owner: one list of the picked filter; a later pick drops its reply.
        Task { await store.select(filter) }
    }

    /// Draws `next`: the picked filter, then the rows in view (or the placeholder with none).
    func apply(_ next: Shown) {
        let membersChanged = next.members != shown.members
        shown = next
        for (button, filter) in zip(filters, CloudTeamSessionStore.Filter.allCases) {
            button.isSelected = next.filter == filter
        }
        placeholder.stringValue = next.placeholder
        placeholder.isHidden = !next.sessions.isEmpty
        scroll.isHidden = next.sessions.isEmpty
        // Members only feed a row's Reassign To menu: handed over, nothing redrawn.
        if membersChanged { for row in made.values { row.members = next.members } }
        realize()
        needsLayout = true
    }

    private func recolor() {
        placeholder.textColor = colors.secondary
        for button in filters { button.colors = colors }
        for row in made.values {
            guard let session = row.row else { continue }
            configure(row, session)
        }
    }

    /// The rows of `count` to make for a clip showing `visible`: those in it and one viewport past each
    /// edge. Before the first layout (no clip height yet) the viewport is the section's tallest.
    static func realizedRange(count: Int, visible: NSRect) -> Range<Int> {
        FixedRowWindow.range(count: count, top: Double(visible.minY), height: Double(visible.height),
                             rowHeight: Double(rowHeight), fallbackHeight: Double(rowHeight) * Double(maxRows))
    }

    /// Makes the rows in range, each matched to its session by key (`FixedRowWindow.remount`): a row whose
    /// session did not change is not configured again, a moved one is only framed, and one that left the
    /// range goes spare.
    private func realize() {
        let sessions = shown.sessions
        let width = scroll.contentSize.width
        let range = Self.realizedRange(count: sessions.count, visible: scroll.contentView.bounds)
        listWork.walked(range.count)
        let inRange = sessions[range].map { (key: $0.key, item: Optional($0)) }
        let plan = FixedRowWindow.remount(window: inRange, mounted: made.mapValues(\.row))
        for key in plan.released {
            guard let row = made.removeValue(forKey: key) else { continue }
            row.removeFromSuperview()
            spare.append(row)
        }
        var toConfigure = Set(plan.configure)
        var kept: [String: CloudTeamSessionRowView] = [:]
        var ordered: [NSView] = []
        var remade = false
        for position in plan.placed {
            let session = sessions[range.lowerBound + position]
            let row: CloudTeamSessionRowView
            if let old = made[session.key] {
                row = old
            } else {
                row = spare.popLast() ?? makeRow()
                remade = true
            }
            if toConfigure.remove(position) != nil { configure(row, session) }
            let frame = NSRect(x: 0, y: Self.rowHeight * CGFloat(range.lowerBound + position), width: width,
                               height: Self.rowHeight)
            if row.frame != frame {
                row.frame = frame
                listWork.laidOut()
                remade = true
            }
            kept[session.key] = row
            ordered.append(row)
        }
        made = kept
        // Subviews top-down, so accessibility and the key loop read the rows in list order.
        if list.subviews != ordered { list.subviews = ordered }
        // A reused or moved row under a still pointer: hover from where the rows are now.
        if remade, let window { PointerHover.refresh(in: window) }
    }

    private func makeRow() -> CloudTeamSessionRowView { CloudTeamSessionRowView(actions: actions) }

    private func configure(_ row: CloudTeamSessionRowView, _ session: CloudTeamSession) {
        row.configure(session, members: shown.members, colors: colors)
        listWork.configured()
    }

    private func watch() {
        let store = store
        // task-owner: the view's one observation of what it draws; it ends once the view is released.
        Task { [weak self] in
            for await next in ObservationStream({ CloudTeamSectionView.shown(store) }) {
                // A released view ends its watch at the next change.
                guard let self else { return }
                guard next != shown else { continue }
                apply(next)
            }
        }
        // task-owner: one list per team (a team switch lists the new team's); it ends once the view is released.
        Task { [weak self] in
            for await _ in ObservationStream({ store.team }) {
                guard self != nil else { return }
                await store.refresh()
                if store.members.isEmpty { _ = try? await store.loadMembers() }
            }
        }
    }

    override func layout() {
        super.layout()
        var x: CGFloat = 6
        for button in filters {
            let size = button.preferredSize
            button.frame = NSRect(x: x, y: (Self.filterHeight - size.height) / 2, width: size.width, height: size.height)
            x = button.frame.maxX + 2
        }
        let below = NSRect(x: 0, y: Self.filterHeight, width: bounds.width, height: max(0, bounds.height - Self.filterHeight))
        placeholder.frame = NSRect(x: 8, y: below.minY, width: max(0, bounds.width - 16), height: min(Self.rowHeight, below.height))
        scroll.frame = below
        let width = scroll.contentSize.width
        let listFrame = NSRect(x: 0, y: 0, width: width, height: Self.rowHeight * CGFloat(shown.sessions.count))
        if list.frame != listFrame { list.frame = listFrame }
        realize()
    }
}

extension CloudTeamSectionView: VisibleRowsList {
    /// Row views alive: the shown ones and the spares.
    var rowViewsAlive: Int { made.count + spare.count }
}

/// The rows' clip: tells the section when what it shows moves (a scroll) or resizes, so the rows in
/// view are made then, with no notification observer.
@MainActor
final class CloudTeamRowClip: NSClipView {
    var onBoundsChange: (() -> Void)?

    override func setBoundsOrigin(_ newOrigin: NSPoint) {
        let moved = newOrigin != bounds.origin
        super.setBoundsOrigin(newOrigin)
        if moved { onBoundsChange?() }
    }

    override func setFrameSize(_ newSize: NSSize) {
        let resized = newSize != frame.size
        super.setFrameSize(newSize)
        if resized { onBoundsChange?() }
    }
}

/// The rows' document view: top-down, as the section is.
@MainActor
final class CloudTeamRowList: NSView {
    override var isFlipped: Bool { true }
}
