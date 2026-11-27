public import AppKit
public import CmuxHomeCore
public import CmuxNextDesign
public import CmuxNextHomeModel
import MessagesLabSidebar
import Observation

/// The Home page's left column: MessagesLab's conversation list
/// (`CmuxSidebarView`, vendored byte-identical) drawing a `HomeSidebarModel`
/// on the chat's own fill (Home's one veil: `Palette.fill(for: .home)`, clear over a
/// translucent window), so the workspace sidebar, this list and the chat read as one
/// colour over the window's tint or background image (the user, 2026-10-31: "chief
/// sidebar bg and chief header bg needs to be same as rest of the bgs"; a 35% scrim of
/// its own made it a third grey). No vibrancy material (it drew a solid gray panel). It owns no data: the page gives it the model
/// after every change and handles the choices.
public final class HomeSidebarView: NSView, WindowControlsAvoiding {
    public var onSelect: (ConversationID) -> Void = { _ in }
    /// The person opened a conversation: a plain click on its row or pinned tile (the selected one
    /// too) or Return on the highlighted one. Called after ``onSelect``; Up/Down and Command- or
    /// Shift-clicks only select. The page moves the keyboard into its message box.
    public var onOpen: (ConversationID) -> Void = { _ in }
    public var onSetPinned: (Bool, ConversationID) -> Void = { _, _ in }
    /// A drag put a conversation at an index of the pinned grid (a new place, or a row pinned
    /// there); call `update` before returning so the tiles land smoothly.
    public var onPlacePinned: (ConversationID, Int) -> Void = { _, _ in }
    /// Mark as Read (the menu offers it while the conversation is unread or marked unread).
    public var onMarkRead: (ConversationID) -> Void = { _ in }
    /// Mark as Unread (the menu offers it while the conversation is read).
    public var onMarkUnread: (ConversationID) -> Void = { _ in }
    /// The host's context-menu items for a conversation (Archive Chief on a Chief).
    public var menuItems: (ConversationID) -> [NSMenuItem] = { _ in [] }
    /// Delete Conversation… on a row's menu and its left swipe (nil: not offered). A teammate row has none.
    public var onDelete: ((ConversationID) -> Void)? {
        didSet {
            guard let onDelete else { list.onDelete = nil; return }
            list.onDelete = { [weak self] id in
                guard let self, teammate(for: id) == nil else { return }
                onDelete(ConversationID(id))
            }
        }
    }
    /// Teammates matching a query that have no DM yet (the list's extra search section). Without
    /// a search, the model's ``HomeSidebarModel/teammates`` are rows after the conversations.
    public var teammates: (String) -> [HomeContact] = { _ in [] }
    /// A teammate from the search section or a teammate row was chosen: start (or open) the DM.
    public var onStartTeammate: (HomeContact) -> Void = { _ in }
    public var onNewMessage: () -> Void = {}
    /// The x on the New Message draft row (shown while the pointer is over it, as in Messages)
    /// was clicked: the page discards the draft (`home.closeNewMessage`).
    public var onCloseDraft: () -> Void = {}
    /// The compose button's right-click menu (New Chief, Invite), or nil for none.
    public var composeMenu: () -> NSMenu? = { nil }
    /// The Message Requests button was clicked (`showRequests`).
    public var onOpenRequests: () -> Void = {}
    /// The unread dot's color: the user's `notifications.attention.color`; nil is the notification blue.
    public var unreadDotColor: NSColor? { didSet { if unreadDotColor != oldValue { applyColors() } } }

    /// Made on first use, after `init` installs the host hooks (`HomeReduceMotion.install()`): the list sets its
    /// controls' tooltips while it is made, so a list made before the hooks would draw AppKit's stock tooltip.
    private(set) lazy var list = CmuxSidebarView()
    /// Messages' floating sidebar (macOS 26, the user 2026-11-23: "EXACTLY like imessage"): the list,
    /// its note and Message Requests in a rounded panel 8 pt in from the column's left, top and
    /// bottom, in the App Store build's glass (the user: "that one has a pretty good sidebar",
    /// `HomeSidebarGlass`): a neutral frost, a deep blue light from above, a one-pixel rim lit blue at
    /// the top and a soft shadow under it.
    let panel = NSView()
    /// The panel's inset from the column's left, top and bottom edges.
    static let panelInset: CGFloat = 8
    /// The panel's corner radius (Messages' sidebar, macOS 26: 18 pt, circular).
    static let panelCornerRadius: CGFloat = 18
    /// The traffic lights' line below the panel's top edge, as in Messages (macOS 26): the filter on
    /// that line sits as far in from the panel's top as from its right (the user, 2026-11-23: "imsg
    /// seems to just do it better"). The panel's top comes up to keep it, never past 2 pt.
    static let lightsBelowPanelTop: CGFloat = 17.5
    /// The selected chat's fill: Messages' selection, the system blue (10 132 255 in dark), whatever
    /// the theme's or the system's accent (the user, 2026-11-23: "make sure that the selected colour is blue").
    static let selectionBlue = NSColor.systemBlue
    /// The light from above: a wash under the top edge, under the list (``HomeSidebarGlass``).
    let wash = CAGradientLayer()
    /// The glass at the last ``applyColors()``: the wash's stops are in points, so layout reads them.
    private var glass: HomeSidebarGlass?
    /// The panel's one-pixel rim over everything in it.
    let rim = HomePanelRimView()
    /// The panel's two soft shadows, behind it.
    let panelShadow = HomePanelShadowView()
    /// The header band behind its row: a drag on its empty space moves the window, as on
    /// Messages' sidebar toolbar.
    let dragStrip = HomeWindowDragStrip()
    /// The header row (`HomeSidebarHeaderLayout`): search and the Unread toggle; the list's compose
    /// stays hidden (``chatCompose``).
    let compose = HomeHeaderButton(symbol: "square.and.pencil", label: HomeConversationStrings.newMessage,
                                   identifier: "cmux.home.sidebar.compose")
    /// All or Unread: one click, Messages' bare filter glyph on the lights' line (on its glass
    /// circle, `filterGlass`, only in the avatar-only list), lit while only unread conversations
    /// show (Home offers no other filter, so no menu).
    let unreadToggle = HomeHeaderButton(symbol: "line.3.horizontal.decrease", onSymbol: "line.3.horizontal.decrease",
                                        label: CmuxSidebarView.unreadTitle, identifier: "cmux.home.sidebar.unread", glass: true)
    /// The Unread toggle's glass circle, under it in the header (Messages' round glass filter
    /// button, the user 2026-10-28): Liquid Glass on macOS 26 and later, the frosted material before.
    let filterGlass = GlassPanelView(style: .regular, cornerRadius: HomeSidebarHeaderMetrics.standard.side / 2) // glass-level-allow: a round or capsule control in the system's untinted button glass, as Messages draws it (the user, 2026-10-28)
    /// The avatar-only list's search: Messages' magnifier on a glass circle (`searchGlass`) beside
    /// the Unread toggle; a click opens the search over the band, as ⌘F does.
    let searchButton = HomeHeaderButton(symbol: "magnifyingglass", label: CmuxSidebarView.searchTitle,
                                        identifier: "cmux.home.sidebar.searchIcon", glass: true)
    /// The search circle's glass, under it in the header.
    let searchGlass = GlassPanelView(style: .regular, cornerRadius: HomeSidebarHeaderMetrics.standard.side / 2) // glass-level-allow: a round or capsule control in the system's untinted button glass, as Messages draws it (the user, 2026-10-28)
    /// The avatar-only list's two circles in the search field's own look (``applySearchColors()``),
    /// so search reads the same at every width (the user, 2026-11-23); the glass circles stay hidden.
    let searchDisc = HomeHeaderDisc()
    let filterDisc = HomeHeaderDisc()
    /// Compose at the chat's top-left at every list width, as in Messages (`HomeChatColumnView`,
    /// which `HomeSidebarSplitView` places beside this list); the list's `compose` stays hidden.
    let chatCompose = HomeChatComposeButton(label: HomeConversationStrings.newMessage)
    /// The header's sizes at the sidebar's density and text size (`followHeaderMetrics`).
    private(set) var headerMetrics = HomeSidebarHeaderMetrics.current
    /// The on filter's chip under the search row (Unread ×): a click turns the filter off.
    let filterChip = HomeFilterChip(title: CmuxSidebarView.unreadTitle, metrics: .current)
    /// The search field's glass capsule (Messages' search field, the user 2026-10-28); a hairline
    /// rim shows while the field edits (the composer's focus, #22114), never AppKit's blue ring.
    let searchCapsule = HomeSearchCapsule()
    /// The header's frames at the last layout (tests, `debug.home.sidebar_fixture`).
    public private(set) var header = HomeSidebarHeaderLayout(width: 320, searchOpen: false)
    /// A quiet line under the list (`HomeSidebarModel.note`).
    let noteLabel = ChromeLabel(labelWithString: "")
    /// "Message Requests (2)" under the list while there are requests (DESIGN 2.3); hidden otherwise.
    let requestsButton = NSButton(title: "", target: nil, action: nil)
    public private(set) var model = HomeSidebarModel(rows: [], pins: HomePins(), me: nil)
    /// The New Message draft's row title (Messages' "New Message" row at
    /// the top of the list while a draft is open or kept), or nil for none.
    public private(set) var draftRowTitle: String?
    /// The draft row's id in `onSelect` (the New Message page's).
    public static let draftRowID = HomeNewMessageComposerSource.conversation

    public override init(frame: NSRect) {
        HomeReduceMotion.install()
        super.init(frame: frame)
        wantsLayer = true
        panel.wantsLayer = true
        panel.layer?.cornerRadius = Self.panelCornerRadius // concentric-allow: Messages' sidebar panel radius, measured; it holds rows, not a button row
        // Circular, as the rim's stroke draws.
        panel.layer?.cornerCurve = .circular
        panel.layer?.masksToBounds = true
        HomeSidebarGlass.configure(wash: wash)
        panel.layer?.addSublayer(wash)
        addSubview(panelShadow)
        addSubview(panel)
        list.frame = panel.bounds
        panel.addSubview(list)
        SystemScrollers.follow(list.scrollView)
        installHeader()
        followHeaderMetrics()
        noteLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        noteLabel.lineBreakMode = .byTruncatingTail
        noteLabel.isHidden = true
        noteLabel.setAccessibilityIdentifier("cmux.home.sidebar.note")
        panel.addSubview(noteLabel)
        requestsButton.bezelStyle = .accessoryBarAction
        requestsButton.isBordered = false
        requestsButton.alignment = .left
        requestsButton.font = .systemFont(ofSize: TypeScale.caption, weight: TypeScale.emphasis)
        requestsButton.image = NSImage(systemSymbolName: "tray", accessibilityDescription: nil)
        requestsButton.imagePosition = .imageLeading
        requestsButton.target = self
        requestsButton.action = #selector(openRequests)
        requestsButton.isHidden = true
        requestsButton.setAccessibilityIdentifier("cmux.home.sidebar.requests")
        panel.addSubview(requestsButton)
        panel.addSubview(rim)
        // The selected chat in blue with white text, as in Messages (the user, 2026-11-23).
        list.neutralSelection = false
        // A teammate row is a person, not a conversation: choosing it starts the DM, and it has
        // no pin, read state or conversation menu.
        list.onSelect = { [weak self] id in
            guard let self, let id else { return }
            if let person = teammate(for: id) { onStartTeammate(person) } else { onSelect(ConversationID(id)) }
        }
        list.onOpen = { [weak self] id in
            guard let self, teammate(for: id) == nil else { return }
            onOpen(ConversationID(id))
        }
        list.onSetPinned = { [weak self] on, id in
            guard let self, teammate(for: id) == nil else { return }
            onSetPinned(on, ConversationID(id))
        }
        list.onPlacePinned = { [weak self] id, index in
            guard let self, teammate(for: id) == nil else { return }
            onPlacePinned(ConversationID(id), index)
        }
        list.onSetRead = { [weak self] read, id in
            guard let self, teammate(for: id) == nil else { return }
            if read { onMarkRead(ConversationID(id)) } else { onMarkUnread(ConversationID(id)) }
        }
        list.menuItems = { [weak self] id in
            guard let self, teammate(for: id) == nil else { return [] }
            return menuItems(ConversationID(id))
        }
        list.searchSection = { [weak self] query in
            guard let self else { return nil }
            let people = teammates(query)
            guard !people.isEmpty else { return nil }
            return CmuxSidebarSearchSection(title: HomeConversationStrings.teammatesSection, results: people.map {
                CmuxSidebarSearchResult(id: $0.id.rawValue, title: $0.name, initials: Self.initials($0.name))
            })
        }
        list.closeTitle = HomeConversationStrings.closeNewMessage
        list.onClose = { [weak self] id in
            guard let self, id == Self.draftRowID.rawValue else { return }
            onCloseDraft()
        }
        list.onSelectSearchResult = { [weak self] id in
            guard let self, let person = teammates(list.searchQuery).first(where: { $0.id.rawValue == id }) else { return }
            onStartTeammate(person)
        }
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The compact list's width and the width the list is designed for (MessagesLab's), with the
    /// panel's left inset: Messages' panel is 320 pt wide at the standard width.
    public var minimumWidth: CGFloat { list.minimumWidth + Self.panelInset }
    public var preferredWidth: CGFloat { list.preferredWidth + Self.panelInset }
    public var selection: ConversationID? { list.selectedID.map { ConversationID($0) } }

    public func update(_ model: HomeSidebarModel) {
        guard model != self.model else { return }
        self.model = model
        reshow()
        noteLabel.stringValue = model.note ?? ""
        if noteLabel.isHidden != (model.note == nil) {
            noteLabel.isHidden = model.note == nil
            needsLayout = true
        }
        onContentChange()
    }

    /// The list holds at most one conversation and nothing under it (no note, no Message Requests):
    /// avatars only, it would be one avatar in an empty band (`HomeSidebarSplitView` folds it then).
    /// The New Message draft row does not count: it comes and goes with the page.
    public var holdsOneConversation: Bool {
        model.pinned.count + model.rows.count <= 1 && noteLabel.isHidden && requestsButton.isHidden
    }

    /// ``holdsOneConversation`` may have changed (the split view lays out again).
    var onContentChange: () -> Void = {}

    /// Shows or removes the New Message draft row (first under the pinned
    /// grid, no time, as in Messages). The row shows an x while the pointer
    /// is over it (``onCloseDraft``).
    public func setDraftRow(_ title: String?) {
        guard title != draftRowTitle else { return }
        draftRowTitle = title
        list.closableID = title == nil ? nil : Self.draftRowID.rawValue
        reshow()
    }

    private func reshow() {
        var entries = (model.pinned + model.rows).map(Self.entry)
        if let draftRowTitle {
            entries.insert(CmuxSidebarEntry(id: Self.draftRowID.rawValue, title: draftRowTitle, people: [], preview: "", previewSender: nil,
                                            lastAt: .distantPast, unreadCount: 0, pinned: false, muted: false, avatar: nil),
                           at: model.pinned.count)
        }
        entries += model.teammates.map(Self.teammateEntry)
        list.show(entries, pinned: model.pinned.map(\.id.rawValue))
    }

    /// The teammate a list id names (``teammateRowID(_:)``), or nil for a conversation.
    func teammate(for id: String) -> HomeContact? {
        guard id.hasPrefix(Self.teammateRowPrefix) else { return nil }
        return model.teammates.first { Self.teammateRowID($0) == id }
    }

    /// A teammate as a list row: their name and monogram, no preview or time (as the draft row).
    static func teammateEntry(_ contact: HomeContact) -> CmuxSidebarEntry {
        CmuxSidebarEntry(id: teammateRowID(contact), title: contact.name,
                         people: [CmuxSidebarEntry.Person(id: contact.id.rawValue, name: contact.name, initials: initials(contact.name))],
                         preview: "", previewSender: nil, lastAt: .distantPast, unreadCount: 0, pinned: false, muted: false,
                         avatar: nil)
    }

    /// Each pinned tile's and row's frame in window points from the top-left (`debug.home page`).
    public var itemFramesInWindow: [(id: ConversationID, pinned: Bool, frame: NSRect)] {
        list.itemFramesInWindow.map { (ConversationID($0.id), $0.pinned, $0.frame) }
    }

    /// The New Message row's centre in window base coordinates, or nil without the row (a
    /// synthesized hover over it shows its x: `debug.home.sidebar_fixture hover_draft`).
    public var draftRowCenterInWindow: NSPoint? {
        guard let window, let frame = itemFramesInWindow.first(where: { $0.id == Self.draftRowID })?.frame else { return nil }
        return NSPoint(x: frame.midX, y: (window.contentView?.bounds.height ?? window.frame.height) - frame.midY)
    }

    /// Selects `id` without reporting it (the page already shows it).
    public func select(_ id: ConversationID?) { list.select(id?.rawValue) }

    static func entry(_ item: HomeSidebarItem) -> CmuxSidebarEntry {
        CmuxSidebarEntry(id: item.id.rawValue, title: item.title,
                         people: item.people.map { CmuxSidebarEntry.Person(id: $0.id, name: $0.name, initials: $0.initials) },
                         preview: item.preview, previewSender: nil, lastAt: item.lastAt, unreadCount: item.unreadCount,
                         pinned: item.isPinned, muted: item.isMuted, avatar: item.chiefAvatar.map(avatar), badge: item.listBadge ?? item.backendBadge)
    }

    /// The Chief's avatar as the list draws it: the picture, else its text
    /// as a monogram (one or two letters) or on the grey disc (an emoji).
    /// The disc fits an emoji's drawn box to 60 % of its width, so two
    /// would each draw small: a two-emoji avatar shows its first in the list.
    static func avatar(_ chief: HomeChiefAvatar) -> CmuxSidebarEntry.Avatar {
        switch chief {
        case .picture(let url): return .image(url.absoluteString)
        case .text(let text): return chief.isMonogram ? .monogram(String(text.prefix(2))) : .emoji(String(text.prefix(1)))
        }
    }

    @objc func newMessage() { onNewMessage() }
    @objc func openRequests() { onOpenRequests() }

    /// Shows the Message Requests button for `count` open requests; none hides it.
    public func showRequests(_ count: Int) {
        let title = count > 0 ? HomeConversationStrings.requestsBar(count) : ""
        guard requestsButton.title != title || requestsButton.isHidden != (count == 0) else { return }
        requestsButton.title = title
        requestsButton.setAccessibilityLabel(title)
        if requestsButton.isHidden != (count == 0) {
            requestsButton.isHidden = count == 0
            needsLayout = true
            onContentChange()
        }
    }

    /// A context-menu item for `menuItems` that runs `handler`.
    public static func menuItem(_ title: String, handler: @escaping () -> Void) -> NSMenuItem {
        CmuxSidebarMenuItem(title: title, handler: handler)
    }

    /// The list id of a teammate's row (a person with no DM yet).
    public static func teammateRowID(_ contact: HomeContact) -> String { teammateRowPrefix + contact.id.rawValue }
    static let teammateRowPrefix = "teammate:"

    /// One or two letters for a teammate's monogram.
    static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: \.isWhitespace)
        return String(words.prefix(2).compactMap(\.first)).uppercased()
    }

    /// The unread dot is the notification blue, as in Messages and on the unread rings (or the
    /// user's `unreadDotColor`), never the theme accent: the default theme's accent is a grey, and
    /// the dot read as missing (the user, 2026-10-21). The column paints Home's one veil, the
    /// chat's fill; the selection is the theme's translucent selection tint, never the system blue.
    func applyColors() {
        list.unreadColor = unreadDotColor ?? performWithTheme { Palette.notificationBlue }
        noteLabel.textColor = performWithTheme { Palette.textSecondary }
        requestsButton.contentTintColor = performWithTheme { Palette.textSecondary }
        // The selected chat: Messages' selection blue, whatever the theme's accent.
        list.selectionColor = Self.selectionBlue
        let fill = performWithTheme { Palette.fill(for: .home, default: Palette.paneFill) }
        let text = performWithTheme { Palette.textPrimary }
        list.neutralSelectionFill = text.withAlphaComponent(0.07)
        layer?.backgroundColor = fill.cgColor
        // What already covers the desktop under the panel: the window's tint, then the column's fill.
        let windowTint = performWithTheme { WindowBackdrop.currentTint(themeTokens) }
        let cover = 1 - (1 - windowTint) * (1 - Double(fill.alphaComponent))
        let glass = HomeSidebarGlass(surface: performWithTheme { Palette.windowBackground }, cover: cover, dark: themeTokens.isDark)
        panel.layer?.backgroundColor = glass.tint.cgColor
        self.glass = glass
        layoutWash()
        rim.apply(glass)
        panelShadow.apply(glass)
        for button in [compose, unreadToggle, searchButton] { button.applyTint() }
        applySearchColors()
    }

    // MARK: Header

    /// The search field without AppKit's bezel and focus ring, in its capsule; the buttons; the
    /// row laid out by `HomeSidebarHeaderLayout` on every list layout.
    private func installHeader() {
        let host = list.headerView
        host.addSubview(dragStrip, positioned: .below, relativeTo: nil)
        searchCapsule.wantsLayer = true
        searchCapsule.layer?.cornerCurve = .continuous
        host.addSubview(searchCapsule, positioned: .below, relativeTo: list.searchField)
        let field = list.searchField
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.setAccessibilityIdentifier("cmux.home.sidebar.search")
        field.onEditingChange = { [weak self] _ in self?.searchEditingChanged() }
        // An emptied field (its cancel button) closes the search over an avatar-only list once it stops editing.
        field.onTextChange = { [weak self] in self?.list.headerView.needsLayout = true }
        searchCapsule.onClick = { [weak self] in self?.openSearch() }
        compose.target = self
        compose.action = #selector(newMessage)
        compose.contextMenu = { [weak self] in self?.composeMenu() }
        chatCompose.target = self
        chatCompose.action = #selector(newMessage)
        chatCompose.contextMenu = { [weak self] in self?.composeMenu() }
        unreadToggle.target = self
        unreadToggle.action = #selector(toggleUnread)
        searchButton.target = self
        searchButton.action = #selector(openSearch)
        host.addSubview(filterGlass)
        host.addSubview(searchGlass)
        host.addSubview(filterDisc)
        host.addSubview(searchDisc)
        for button in [unreadToggle, searchButton, compose] { host.addSubview(button) }
        filterChip.isHidden = true
        filterChip.target = self
        filterChip.action = #selector(showAll)
        host.addSubview(filterChip)
        // The empty list's Show All turns the filter off the same way.
        list.onShowAll = { [weak self] in self?.showAll() }
        list.layoutHeader = { [weak self] bounds in self?.layoutHeader(bounds) ?? HomeSidebarHeaderLayout.band }
    }

    /// The search is open while the field edits or holds a query.
    var searchOpen: Bool { list.searchField.isEditing || !list.searchField.stringValue.isEmpty }

    /// The traffic lights' row over the header's band at its last layout (`homeLightsRow`).
    private var windowControls: CGRect?

    /// Re-reads the traffic lights after the list moved in its window without a resize of its
    /// header (the window's sidebar opened or closed beside the Home page); relays out the header
    /// only when what lies over it changed. `HomeSidebarSplitView` calls it on every layout.
    public func updateWindowControlsAvoidance() {
        // The panel's top follows the lights' line, which a density change moves with no resize. Laid out now, as the
        // header below: the window re-checks after its layout pass (`WindowControlsAvoiders.batching`), and a mark
        // alone waited for the next pass, a frame late.
        if abs((bounds.height - panel.frame.maxY) - panelTopInset) > 0.25 {
            needsLayout = true
            layoutSubtreeIfNeeded()
        }
        guard list.headerView.homeLightsRow(band: HomeSidebarHeaderLayout.band) != windowControls else { return }
        // The header's layout also places the list under it (its height may change). Laid out
        // now, not at the next display pass: an occluded window gets none until it shows, and
        // the next frame on screen would still have the search field under the lights.
        list.headerView.needsLayout = true
        list.headerView.layoutSubtreeIfNeeded()
    }

    private func layoutHeader(_ bounds: CGRect) -> CGFloat {
        // One header, lights over the list or not: the lights' row (`homeLightsRow`) is the top row
        // either way and the same in both, so a toggle of the window's sidebar moves Home sideways
        // only. A list clear of the lights keeps their row with nothing on it; full screen, with
        // no lights, has the one-row band.
        let row = list.headerView.homeLightsRow(band: HomeSidebarHeaderLayout.band)
        windowControls = row
        // The row's x is as the lights lie over a list at the window's left edge, and the list
        // (the panel) starts ``panelInset`` in from the column's.
        let controls = row?.offsetBy(dx: -Self.panelInset, dy: 0)
        var chipRow = unreadOnly, chipFill = false, chipCentered = false
        #if DEBUG || CMUX_BENCH_HOOKS
        chipRow = unreadOnly && debugFilterLook.showsChip
        chipFill = debugFilterLook == .banner
        chipCentered = debugFilterLook == .centeredChip
        #endif
        let h = HomeSidebarHeaderLayout(width: bounds.width, searchOpen: searchOpen, windowControls: controls, filterOn: chipRow,
                                        metrics: headerMetrics)
        header = h
        filterChip.isHidden = h.filterChip.isEmpty
        if !h.filterChip.isEmpty {
            let w = chipFill ? h.filterChip.width : min(h.filterChip.width, filterChip.fittingSize.width)
            filterChip.frame = CGRect(x: h.compact || chipCentered ? ((bounds.width - w) / 2).rounded() : h.filterChip.minX,
                                      y: h.filterChip.minY, width: w, height: h.filterChip.height)
        }
        dragStrip.frame = CGRect(x: 0, y: 0, width: bounds.width, height: h.listTop)
        let compactClosed = h.compact && !h.buttonsCovered
        searchCapsule.frame = h.search
        searchCapsule.isHidden = compactClosed
        searchCapsule.layer?.cornerRadius = h.search.height / 2
        // The field inside its capsule, its text centred on the row: an unbezeled search cell draws
        // its line from the frame's top, so the field is one text line tall (a 22 pt field put the
        // text 2.75 pt above the buttons' centre line). In the avatar-only list it waits closed at
        // zero width (alpha 0), so ⌘F and type-to-search still reach it and open it over the band,
        // and the band stays the window's drag area.
        let fieldHeight = list.searchField.font.map { ceil(NSLayoutManager().defaultLineHeight(for: $0)) } ?? 22
        if compactClosed {
            list.searchField.frame = CGRect(x: h.search.minX, y: h.search.midY - fieldHeight / 2, width: 0, height: fieldHeight)
            list.searchField.alphaValue = 0
            list.searchField.setAccessibilityElement(false)
        } else {
            // Messages' magnifier sits about 13 pt inside the capsule (the field's own icon 5 pt in).
            list.searchField.frame = CGRect(x: h.search.minX + 8, y: h.search.midY - fieldHeight / 2,
                                            width: max(0, h.search.width - 16), height: fieldHeight)
            list.searchField.alphaValue = 1
            list.searchField.setAccessibilityElement(true)
        }
        unreadToggle.fixedGlyphSize = h.filterGlyph
        unreadToggle.frame = h.filter
        compose.frame = h.compose
        unreadToggle.isHidden = h.filter.isEmpty
        // Messages draws the filter bare on its sidebar's glass; the glass circle stays for the
        // avatar-only list's pair of circles.
        filterGlass.isHidden = true
        filterDisc.frame = h.filter
        filterDisc.isHidden = h.filter.isEmpty || !h.compact
        searchButton.frame = h.searchIcon
        searchButton.isHidden = h.searchIcon.isEmpty
        searchGlass.isHidden = true
        searchDisc.frame = h.searchIcon
        searchDisc.isHidden = h.searchIcon.isEmpty
        // Compose is the chat's (`chatCompose`) at every width.
        compose.isHidden = true
        return h.listTop
    }

    /// `sidebar.density` and `sidebar.textSize`, live: the filter circle, the search field, the
    /// Unread chip and the empty list's text take the new sizes, and the header lays out again.
    private func followHeaderMetrics() {
        let metrics = withObservationTracking {
            HomeSidebarHeaderMetrics.current
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.followHeaderMetrics() }
        }
        filterChip.metrics = metrics
        list.emptyTextStep = metrics.emptyTextStep
        // Another sidebar setting changed (the same sizes): no new layout.
        guard metrics != headerMetrics else { return }
        headerMetrics = metrics
        list.headerView.needsLayout = true
    }

    /// Focus moves into or out of the field: the ring steps, the caret takes the accent, and in
    /// the avatar-only list the search opens over the band or closes.
    private func searchEditingChanged() {
        applySearchColors()
        list.headerView.needsLayout = true
    }

    /// The capsule's focus rim, and the field's text, placeholder and caret, in the theme scope.
    /// The field's look at rest: a faint fill and a one-pixel outline of the text at 14 % (10 % in
    /// light); while the field edits the outline is the text at 36 % (the composer's focused edge,
    /// `--acpmux-composer-edge` 18 % stepped 22 % toward the text, doubled to read on glass). The
    /// avatar-only list's circles take the rest look.
    func applySearchColors() {
        let field = list.searchField
        let editing = field.isEditing
        performWithTheme {
            let text = Palette.textPrimary
            // Messages' search field on an opaque fill: no glass. In dark its capsule holds back the
            // light from above (the user's recording, 2026-11-23: 24 28 32 in the field under 20 33 44
            // around it): the surface 3 % toward white at 60 %. Black at 5 % in light. Over a
            // see-through fill the glass keeps the composer's surface under the placeholder
            // (`searchCapsuleTintInScope`).
            let tint = Self.searchCapsuleTintInScope()
            let dark = themeTokens.isDark
            let surface = Palette.fill(for: .home, default: Palette.paneFill)
            let fill = dark ? HomeSidebarGlass.mix(surface.withAlphaComponent(1), 0.97, .white).withAlphaComponent(0.6)
                : NSColor.black.withAlphaComponent(0.05)
            let pixel = 1 / max(1, window?.backingScaleFactor ?? 2)
            let rest = text.withAlphaComponent(dark ? 0.14 : 0.10)
            searchCapsule.glass.isHidden = tint == nil
            searchCapsule.glass.tintColor = tint
            searchCapsule.layer?.backgroundColor = tint != nil ? nil : fill.cgColor
            searchCapsule.layer?.borderColor = editing ? text.withAlphaComponent(0.36).cgColor : rest.cgColor
            searchCapsule.layer?.borderWidth = pixel
            for disc in [searchDisc, filterDisc] {
                disc.layer?.backgroundColor = (tint ?? fill).cgColor
                disc.layer?.borderColor = rest.cgColor
                disc.layer?.borderWidth = pixel
            }
            field.textColor = text
            field.placeholderAttributedString = NSAttributedString(string: searchPlaceholder, attributes: [
                .foregroundColor: Palette.textSecondary,
                .font: field.font ?? .systemFont(ofSize: NSFont.systemFontSize),
            ])
            if let editor = field.currentEditor() as? NSTextView {
                editor.insertionPointColor = Palette.accentFill
                editor.selectedTextAttributes = [.backgroundColor: Palette.textSelection]
            }
        }
    }

    /// The search capsule's tint. Over a see-through Home fill the clear capsule showed the art under
    /// its placeholder (2.05:1 on the Great Wave in dark); there it takes the fill every field takes
    /// (the web composer's surface, `HomeThemePalette.composerSurfaceOverGlass`, the Chief field's
    /// `composeFillOverGlass`). An opaque Home fill keeps the clear glass (nil).
    static func searchCapsuleTintInScope() -> NSColor? { // theme-scoped
        let fill = Palette.fill(for: .home, default: Palette.paneFill).usingColorSpace(.sRGB)
        guard (fill?.alphaComponent ?? 1) < 1 else { return nil }
        let surface = HomeThemePalette.composerSurfaceOverGlass(HomeThemePalette.baseThemeInScope())
        return surface.nsColor
    }

    @objc func toggleUnread() { unreadOnly.toggle() }

    #if DEBUG || CMUX_BENCH_HOOKS
    /// DEBUG ONLY: the playground's way to show an on filter (`debug.home.sidebar_fixture` `filter_look`).
    var debugFilterLook: HomeFilterLook = .chip {
        didSet {
            applySearchColors()
            list.headerView.needsLayout = true
        }
    }
    #endif

    /// The search field's placeholder (DEBUG: the playground's Search Unread variant names the filter).
    private var searchPlaceholder: String {
        #if DEBUG || CMUX_BENCH_HOOKS
        if debugFilterLook == .searchPlaceholder, unreadOnly { return "Search Unread" }
        #endif
        return CmuxSidebarView.searchTitle
    }

    /// The filter chip's click and the empty list's Show All: every conversation shows again.
    @objc func showAll() { unreadOnly = false }

    /// Only unread conversations show (the Unread toggle's state): the toggle lights, the chip
    /// shows under the search row, and an empty list says No Unread Chats with Show All.
    public var unreadOnly: Bool {
        get { list.unreadOnly }
        set {
            list.unreadOnly = newValue
            unreadToggle.isOn = newValue
            // The chip row moves the list down: the header lays out again now.
            list.headerView.needsLayout = true
            #if DEBUG || CMUX_BENCH_HOOKS
            if debugFilterLook == .searchPlaceholder { applySearchColors() }
            #endif
        }
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    /// Screenshots: true gives the search field the keyboard (it opens over an avatar-only list), false
    /// ends the search and takes the keyboard back.
    public func debugSearch(_ open: Bool) {
        if open {
            window?.makeFirstResponder(list.searchField)
        } else {
            list.clearSearch()
            if list.searchField.isEditing { window?.makeFirstResponder(nil) }
        }
        list.headerView.needsLayout = true
    }

    /// Screenshots (`debug.home.sidebar_fixture`), each optional: the list's `width` (clamped as
    /// a divider drag is), selects the `select`-th row (0 first, below the pinned tiles), sets
    /// the Unread toggle, opens or ends the search (`debugSearch`). The answer is a
    /// `JSONSerialization` graph: the list's `width` and the `header` (each frame as [x, y, width,
    /// height], `compact`, `buttonsCovered`, and `chatCompose`, the chat's compose button in window
    /// points from the top-left or NSNull while hidden); nil when `select` names no row, and
    /// nothing changes then. `buttons` is the compose and Unread buttons' glyph state
    /// (`HomeHeaderButton.debugState`) as the call found it (`before`) and after its layout.
    public func debugLook(width: Double?, select: Int?, unread: Bool?, search: Bool?, filterLook: Int? = nil, selectPinned: Int? = nil) -> [String: Any]? {
        if let select, !model.rows.indices.contains(select) { return nil }
        if let selectPinned, !model.pinned.indices.contains(selectPinned) { return nil }
        let before = [compose, unreadToggle, searchButton].map(\.debugState)
        // The header as it stood before this call lays anything out, and the traffic lights it
        // used then and sees now (a stale header under the lights shows here).
        func rect(_ r: CGRect?) -> Any { r.map { [$0.minX, $0.minY, $0.width, $0.height].map(Double.init) } ?? NSNull() }
        let stale: [String: Any] = ["search": rect(header.search), "used": rect(windowControls),
                                    "sees": rect(list.headerView.homeWindowControls(band: HomeSidebarHeaderLayout.band)),
                                    "headerInWindow": rect(list.headerView.convert(list.headerView.bounds, to: nil)),
                                    "lights": rect(window.flatMap { WindowTitlebar.trafficLightsFrame(in: $0) })]
        let split = superview as? HomeSidebarSplitView
        if let width { split?.setWidth(width) }
        if let select {
            onSelect(model.rows[select].id)
            self.select(model.rows[select].id)
        }
        if let selectPinned {
            onSelect(model.pinned[selectPinned].id)
            self.select(model.pinned[selectPinned].id)
        }
        if let filterLook, let look = HomeFilterLook(rawValue: filterLook) { debugFilterLook = look }
        if let unread { unreadOnly = unread }
        if let search { debugSearch(search) }
        (split?.superview ?? self).layoutSubtreeIfNeeded()
        func frame(_ r: CGRect?) -> Any { r.map { [$0.minX, $0.minY, $0.width, $0.height].map(Double.init) } ?? NSNull() }
        let h = header
        var chat: CGRect?
        if !chatCompose.isHidden, let window, let height = window.contentView?.bounds.height {
            let r = chatCompose.convert(chatCompose.bounds, to: nil)
            chat = CGRect(x: r.minX, y: height - r.maxY, width: r.width, height: r.height)
        }
        return ["width": Double(split?.sidebarWidth ?? bounds.width),
                "header": ["search": frame(h.search), "searchIcon": frame(h.searchIcon), "filter": frame(h.filter),
                           "compose": frame(h.compose),
                           "compact": h.compact, "buttonsCovered": h.buttonsCovered,
                           "chatCompose": frame(chat)] as [String: Any],
                "beforeLayout": stale,
                "buttons": ["before": before, "after": [compose, unreadToggle, searchButton].map(\.debugState)]]
    }
    #endif

    /// The search capsule's or the search circle's click: the field takes the keyboard.
    @objc func openSearch() {
        // An edit already under way keeps its caret and selection.
        guard !list.searchField.isEditing else { return }
        window?.makeFirstResponder(list.searchField)
    }

    /// The search field's and the circles' one-pixel outlines follow the display's scale.
    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        applySearchColors()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        WindowControlsAvoiders.join(self)
        applyColors()
        // A new window has its own traffic lights (or none, in full screen).
        updateWindowControlsAvoidance()
    }

    /// A hidden workspace skipped window updates; re-read its position when shown.
    public override func viewDidUnhide() {
        super.viewDidUnhide()
        updateWindowControlsAvoidance()
    }

    /// The panel's inset from the column's top: ``lightsBelowPanelTop`` above the traffic lights'
    /// line when it crosses the column's top band, else ``panelInset`` (full screen).
    var panelTopInset: CGFloat {
        guard let window, let lights = TrafficLightsLine.restingFrame(in: window) else { return Self.panelInset }
        let line = convert(lights, from: nil)
        let fromTop = isFlipped ? line.midY : bounds.maxY - line.midY
        guard fromTop > 0, fromTop < HomeSidebarHeaderLayout.band else { return Self.panelInset }
        return min(Self.panelInset, max(2, (fromTop - Self.lightsBelowPanelTop).rounded()))
    }

    /// The wash in its band under the panel's top edge (stops in points, so colours and frame together).
    private func layoutWash() {
        guard let glass else { return }
        let band = glass.washBand
        let g = HomeSidebarGlass.gradient(glass.wash, height: band)
        wash.colors = g.colors
        wash.locations = g.locations
        wash.frame = CGRect(x: 0, y: panel.bounds.height - band, width: panel.bounds.width, height: band)
    }

    public override func layout() {
        super.layout()
        // The note's and the requests button's strips at the bottom; the list ends above them.
        // The header is the list's (`layoutHeader`), in its flipped root view.
        let inset = Self.panelInset
        let top = panelTopInset
        panel.frame = NSRect(x: inset, y: inset, width: max(0, bounds.width - inset), height: max(0, bounds.height - inset - top))
        let area = panel.bounds
        layoutWash()
        rim.frame = area
        panelShadow.frame = panel.frame
        let note: CGFloat = noteLabel.isHidden ? 0 : 30
        let requests: CGFloat = requestsButton.isHidden ? 0 : 30
        list.frame = NSRect(x: 0, y: note + requests, width: area.width, height: max(0, area.height - note - requests))
        noteLabel.frame = NSRect(x: 14, y: 8, width: max(0, area.width - 28), height: 16)
        requestsButton.frame = NSRect(x: 10, y: note + 4, width: max(0, area.width - 20), height: 22)
    }

}

/// The search field's glass capsule (Messages' search field): Liquid Glass on macOS 26 and later,
/// the frosted material before. A click on it, outside the field, still gives the field the keyboard.
final class HomeSearchCapsule: NSView {
    var onClick: () -> Void = {}
    /// The capsule's glass, edge to edge, its corners half its height.
    let glass = GlassPanelView(style: .regular) // glass-level-allow: a round or capsule control in the system's untinted button glass, as Messages draws it (the user, 2026-10-28)

    init() {
        super.init(frame: .zero)
        addSubview(glass)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) { onClick() }
    /// The glass takes no clicks of its own: they reach the capsule.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, frame.contains(point) else { return nil }
        return self
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        glass.frame = bounds
        glass.cornerRadius = bounds.height / 2
    }
}

/// The avatar-only list's circle under its search or Unread button: the search field's rest look
/// (`HomeSidebarView.applySearchColors`). Takes no clicks: they reach the button over it.
final class HomeHeaderDisc: NSView {
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.actions = ["bounds": NSNull(), "position": NSNull(), "cornerRadius": NSNull()]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layer?.cornerRadius = min(newSize.width, newSize.height) / 2
    }
}

/// Empty header space that is titlebar: it drags the window, and a double-click runs the user's titlebar action.
final class HomeWindowDragStrip: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) { WindowTitlebar.handleMouseDown(event, in: window) }
}
