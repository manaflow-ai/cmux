public import AppKit
public import CmuxNextDesign
public import CmuxNextPages
import CmuxNextWakeups

/// Draws the sidebar's workspace group editor (``SidebarGroupEditorSurface``): the React page
/// webviews/src/pages/group-editor in one warm glass panel, made once (at an idle moment after launch or
/// at the first open) and kept for every later open, like the icon picker.
///
/// Group editors are menus and open at once, fully drawn (#26400, #27056). While closed the panel stays
/// ordered in over its window with its card transparent and click-through, so the page keeps painting
/// (WebKit draws only what is in a window and not hidden). An open pushes the group to the page, which
/// paints it and answers ready with its height; the card is then placed at that height and shown in
/// one step, with no fade or grow in. A page that has not answered after ``readyDeadline`` is shown
/// as it is. Closing fades like every popup, and the card stays transparent in its window for the next open.
@MainActor
public final class GroupEditorService: SidebarGroupEditorSurface {
    /// How long an open waits for the page to paint the group before it shows anyway.
    static let readyDeadline: Duration = .milliseconds(150)
    /// The card's height before the page first reports one.
    static let firstHeight: CGFloat = 360

    /// One editor open.
    struct Open {
        let session: String
        var revision: Int
        var group: SidebarGroup
        let items: [[SidebarGroupEditorItem]]
        let anchor: PopupAnchor
        weak var parent: NSWindow?
        weak var themeAnchor: NSView?
        let events: SidebarGroupEditorEvents
        /// The name the person typed (the page's last draft); nil while the field is untouched, so a name
        /// changed elsewhere meanwhile is never written back.
        var draft: String?
        /// The card shows (the page painted, or the deadline passed).
        var shown = false

        /// The typed name to commit: trimmed, not empty and not the group's name now.
        var typedName: String? {
            guard let name = draft?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty, name != group.name else { return nil }
            return name
        }
    }

    private struct Warm {
        let panel: GroupEditorPanel
        let page: PageWebView
        let provider: GroupEditorProvider
    }

    private var warm: Warm?
    private(set) var open: Open?
    private let icons = GroupEditorIcons()
    private var height = firstHeight
    private var sessions = 0
    private let deadline = DemandTimer(owner: "GroupEditorService.ready")
    /// The app's overlay pages' shared web content process (``PageOverlayProcess``); nil gives the page its own.
    private let overlayProcess: PageOverlayProcess?

    public init(overlayProcess: PageOverlayProcess? = nil) {
        self.overlayProcess = overlayProcess
    }
    /// The page's engine options: it shows in a glass panel that closes when it loses the keys, and a
    /// Chromium page is an opaque child window that takes them.
    public static let engineOptions = PageEngineOptions(requiresWebKit: .transparentOverlay)

    /// The panel, for tests and `debug.popups`.
    var panel: NSPanel? { warm?.panel }
    var provider: GroupEditorProvider? { warm?.provider }

    /// Makes the warm panel and page ahead of the first open.
    public func prepare() {
        _ = warmed()
    }

    private func warmed() -> Warm? {
        if let warm { return warm }
        let provider = GroupEditorProvider()
        guard let page = PageWebView(descriptor: .groupEditor, routes: [PageRoute(prefix: "cmux.groupEditor.", provider: provider)],
                                     options: Self.engineOptions, overlayProcess: overlayProcess) else { return nil }
        let panel = GroupEditorPanel(content: page, width: SidebarGroupEditor.width)
        panel.onDismiss = { [weak self] in self?.dismiss() }
        provider.onCall = { [weak self] call in self?.handle(call) }
        let made = Warm(panel: panel, page: page, provider: provider)
        warm = made
        return made
    }

    // MARK: SidebarGroupEditorSurface

    public func present(_ group: SidebarGroup, items: [[SidebarGroupEditorItem]], anchor: PopupAnchor, parent: NSWindow,
                 themeAnchor: NSView, ordersFront: Bool, events: SidebarGroupEditorEvents) {
        if open != nil { dismiss() }
        guard let warm = warmed() else { return }
        sessions += 1
        let opened = Open(session: "group-editor-\(sessions)", revision: 1, group: group, items: items, anchor: anchor,
                          parent: parent, themeAnchor: themeAnchor, events: events)
        open = opened
        // The page draws in the sidebar's theme at full strength, in each room the editor opens in.
        warm.panel.adoptThemeScope(of: themeAnchor)
        warm.provider.openSession = opened.session
        push(opened)
        guard ordersFront else { return }
        warm.panel.ready(over: parent, frame: frame(anchor: anchor, parent: parent))
        // The keys come to the editor now, as the native bubble's did, so a name typed before the page has painted
        // goes into its field (the page focuses it as it draws the session), not into the window under it.
        warm.panel.makeKey()
        warm.page.focusPage()
        let session = opened.session
        deadline.schedule(after: Self.readyDeadline) { @MainActor [weak self] in
            guard let self, self.open?.session == session, self.open?.shown == false else { return }
            self.reveal()
        }
    }

    public func refresh(_ group: SidebarGroup) {
        guard var open else { return }
        open.revision += 1
        open.group = group
        self.open = open
        push(open)
    }

    public func dismiss() {
        guard let open else { return }
        self.open = nil
        warm?.provider.openSession = nil
        if let name = open.typedName { open.events.rename(name) }
        if let panel = warm?.panel {
            if open.shown {
                panel.close(toward: open.anchor.rect)
            } else {
                // Closed before the page answered: the panel already has the keys (present), so they go back too.
                panel.giveBackKeys()
                panel.veil()
            }
        }
        open.events.close()
    }

    // MARK: The page

    private func push(_ open: Open) {
        let palette = DesignSettings.shared.sidebarSections.groupPalette
        let session = GroupEditorSession(id: open.session, revision: open.revision, group: open.group, items: open.items, draft: open.draft)
        let build = { session.event(palette: palette, icons: self.icons) }
        warm?.provider.push(open.themeAnchor.map { $0.performWithTheme(build) } ?? build())
    }

    private func handle(_ call: GroupEditorProvider.Call) {
        guard var open else { return }
        switch call {
        case let .ready(revision, height):
            guard revision == open.revision else { return }
            self.height = CGFloat(height)
            if open.shown, let parent = open.parent {
                warm?.panel.place(frame(anchor: open.anchor, parent: parent))
            } else {
                reveal()
            }
        case let .draft(name):
            open.draft = name
            self.open = open
            warm?.provider.keep(draft: name)
        case let .color(id):
            guard let color = GroupColor(rawValue: id) else { return }
            open.events.color(color)
        case .customColor:
            open.events.customColor()
            dismiss()
        case let .item(id):
            // The typed name commits before the row runs (a rename then New Workspace in Group).
            if let name = open.typedName {
                open.events.rename(name)
                open.draft = nil
                self.open = open
            }
            open.events.item(id)
            dismiss()
        case .close:
            dismiss()
        }
    }

    /// Shows the card at the page's height, in one step.
    private func reveal() {
        deadline.cancel()
        guard var open, !open.shown, let warm, let parent = open.parent, parent.isVisible else { return }
        open.shown = true
        self.open = open
        warm.panel.place(frame(anchor: open.anchor, parent: parent))
        warm.panel.reveal(over: parent)
        warm.page.focusPage()
    }

    /// The panel's frame (with its shadow band) for the card at the page's height. The page reports CSS pixels and
    /// lays out at the editor's width in CSS pixels, so both are its zoom times that in points.
    func frame(anchor: PopupAnchor, parent: NSWindow) -> NSRect {
        let zoom = CGFloat(warm?.page.pageZoom ?? 1)
        return PopupStyle.standard.windowFrame(forCard: SidebarGroupEditor.cardFrame(anchor: anchor, parent: parent, height: height * zoom,
                                                                                    zoom: zoom))
    }
}

/// The group editor's panel: the page on the popup glass, a child of the sidebar's window. It takes the
/// keys only while the app is active (``ActiveAppKeyPanel``). Between opens it stays ordered in with its
/// card transparent and click-through, so the page paints the next group before it shows.
@MainActor
final class GroupEditorPanel: ActiveAppKeyPanel {
    /// Closes the editor: the panel lost the keys, or Escape.
    var onDismiss: (() -> Void)?
    private let card: NSView
    /// Bumped by every open, close and veil, so a close whose fade ends after a reopen leaves the card shown.
    private var generation = 0

    init(content: NSView, width: CGFloat) {
        let size = NSSize(width: width, height: GroupEditorService.firstHeight)
        card = Glass.makeOverlayPanel(content: content, cornerRadius: PopupStyle.standard.cornerRadius)
        super.init(contentRect: PopupStyle.standard.windowFrame(forCard: NSRect(origin: .zero, size: size)),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isReleasedWhenClosed = false
        hidesOnDeactivate = true
        collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        card.frame = NSRect(origin: .zero, size: size)
        adoptPopupStyle(card: card)
        setAccessibilityLabel(GroupEditorStrings.editor)
        onKeyElsewhere = { [weak self] in self?.onDismiss?() }
    }

    override var canBecomeMain: Bool { false }

    /// The card is transparent (between opens, or before the page has painted).
    var isVeiled: Bool { card.alphaValue == 0 }
    /// The popup's shadow shows; a veiled card casts none.
    var castsShadow: Bool { !((contentView as? PopupHostView)?.shadowLayer.isHidden ?? true) }

    /// The popup's shadow is its own layer beside the card: it hides and shows with it, at once.
    private func showShadow(_ shown: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        (contentView as? PopupHostView)?.shadowLayer.isHidden = !shown
        CATransaction.commit()
    }

    /// Orders the panel in over `parent` at `frame` with its card transparent, so the page paints there.
    func ready(over parent: NSWindow, frame: NSRect) {
        veil()
        setFrame(frame, display: false)
        attach(to: parent)
    }

    func place(_ frame: NSRect) {
        guard frame != self.frame else { return }
        setFrame(frame, display: true)
    }

    /// Shows the card over `parent` in one step (no fade or grow in), also during a closing fade, and takes the keys.
    func reveal(over parent: NSWindow) {
        generation += 1
        attach(to: parent)
        showPopupAtOnce()
        card.alphaValue = 1
        showShadow(true)
        ignoresMouseEvents = false
        makeKey()
    }

    /// Fades the card out toward `anchor` (screen coordinates) like every popup, then leaves it transparent and
    /// click-through in its window, where the page keeps painting for the next open. The keys go back to the
    /// window under it now, not when the fade ends.
    func close(toward anchor: CGRect) {
        generation += 1
        let closing = generation
        ignoresMouseEvents = true
        giveBackKeys()
        closePopup(pivot: popupPivot(toward: anchor)) { [weak self] in
            // A reopen during the fade keeps its card.
            guard let self, self.generation == closing else { return }
            self.veil()
        }
    }

    /// The keys go back to the window under the editor (the panel takes them as an open begins).
    func giveBackKeys() {
        makeFirstResponder(nil)
        if isKeyWindow, let parent, parent.isVisible { parent.makeKey() }
    }

    /// The card transparent and click-through; the panel stays where it is.
    func veil() {
        generation += 1
        card.alphaValue = 0
        showShadow(false)
        resetPopupScale()
        alphaValue = 1
        ignoresMouseEvents = true
    }

    private func attach(to parent: NSWindow) {
        if self.parent !== parent {
            self.parent?.removeChildWindow(self)
            parent.addChildWindow(self, ordered: .above)
        }
        if !isVisible { orderFront(nil) }
    }

    override func resignKey() {
        super.resignKey()
        onDismiss?()
    }

    override func cancelOperation(_ sender: Any?) {
        onDismiss?()
    }
}
