import AppKit
import CmuxNextCompat
import CmuxNextDesign

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
    private(set) var rows: [CloudTeamSessionRowView] = []
    private let placeholder = NSTextField(wrappingLabelWithString: "")
    private let scroll = NSScrollView()
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
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.documentView = list
        SystemScrollers.followThin(scroll)
        addSubview(scroll)
        apply(shown)
        recolor()
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

    /// Draws `next`: the picked filter, then a row per session (or the placeholder with none).
    func apply(_ next: Shown) {
        shown = next
        for (button, filter) in zip(filters, CloudTeamSessionStore.Filter.allCases) {
            button.isSelected = next.filter == filter
        }
        placeholder.stringValue = next.placeholder
        placeholder.isHidden = !next.sessions.isEmpty
        scroll.isHidden = next.sessions.isEmpty
        while rows.count > next.sessions.count {
            rows.popLast()?.removeFromSuperview()
        }
        while rows.count < next.sessions.count {
            let row = CloudTeamSessionRowView(actions: actions)
            list.addSubview(row)
            rows.append(row)
        }
        for (row, session) in zip(rows, next.sessions) {
            row.configure(session, members: next.members, colors: colors)
        }
        needsLayout = true
    }

    private func recolor() {
        placeholder.textColor = colors.secondary
        for button in filters { button.colors = colors }
        for (row, session) in zip(rows, shown.sessions) {
            row.configure(session, members: shown.members, colors: colors)
        }
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
        list.frame = NSRect(x: 0, y: 0, width: width, height: Self.rowHeight * CGFloat(rows.count))
        for (index, row) in rows.enumerated() {
            row.frame = NSRect(x: 0, y: Self.rowHeight * CGFloat(index), width: width, height: Self.rowHeight)
        }
    }
}

/// The rows' document view: top-down, as the section is.
@MainActor
final class CloudTeamRowList: NSView {
    override var isFlipped: Bool { true }
}
