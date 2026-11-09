public import AppKit
import CmuxHomeRender
import CmuxNextCompat
public import CmuxNextDesign
public import CmuxNextHomeModel
public import CmuxNextPages

/// The Chat Colors… panel (a chat row's menu, the palette, `home.chatColors`): one small floating
/// panel for the app, showing one chat at a time; opening it for another chat switches it there.
/// The content is the React page (webviews/src/pages/home-chat-colors), loaded once into one
/// ``PageWebView`` and reused for every open, as the icon picker does (``IconPickerService``).
/// Custom Color opens the system colour panel, attached to this panel; its picks go through the
/// same store path as a swatch and stream back to the page as state.
@MainActor
public final class HomeChatColorsService {
    /// 340 pt wide at 1x (times the page zoom, ``contentSize``); the page's fixed layout is 340 CSS px high (webviews/src/pages/home-chat-colors/styles.css).
    static let size = NSSize(width: 340, height: 340)

    /// The panel's content size at `zoom`: the page's 340 CSS px square times the zoom
    /// `PageWebView` applies (`app.uiScale`), so at 1.5x every row still fits and nothing wraps.
    static func contentSize(zoom: CGFloat) -> NSSize {
        let zoom = max(zoom, 0.5)
        return NSSize(width: (size.width * zoom).rounded(), height: (size.height * zoom).rounded())
    }

    /// The content size now: the page zoom `PageWebView` uses (`DesignSettings.shared.uiScale`).
    var contentSize: NSSize { Self.contentSize(zoom: DesignSettings.shared.uiScale) }
    /// A titled, opaque utility panel: Chromium can host the page (no see-through overlay).
    public static let engineOptions = PageEngineOptions.standard

    let provider: HomeChatColorsProvider
    private var panel: HomeChatColorsWindow?
    private var host: HomeChatColorsHostView?
    /// The system colour panel's borrow while Custom Color has it (``GroupColorPanel`` lends it to
    /// one part of the app at a time; a group editor that takes it ends this one).
    private var colorBorrow: GroupColorPanel.Borrow?
    private var zoomFollower: Task<Void, Never>?

    /// The panel, once shown (tests, `debug.home`).
    var window: NSPanel? { panel }
    /// The page, once made.
    var page: PageWebView? { host?.page }

    /// - Parameters:
    ///   - store: the chats' colours (the Home service's).
    ///   - design: the settings the bubble style and the default for every chat come from.
    public init(store: HomeChatColorStore, design: DesignSettings) {
        provider = HomeChatColorsProvider(store: store, design: design)
        provider.themeView = { [weak self] in self?.host }
        provider.onDone = { [weak self] in self?.close() }
        provider.onCustomColor = { [weak self] role, start in self?.showColorPanel(for: role, from: start) }
    }

    /// Shows the panel for `conversation`, over `window` when there is one.
    /// - Parameters:
    ///   - conversation: the chat's conversation id.
    ///   - name: the chat's name, in the panel's title.
    ///   - window: the window it opens over.
    public func show(conversation: String, name: String, over window: NSWindow?) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        releaseColorPanel()
        provider.begin(HomeChatColorsProvider.Session(id: UUID().uuidString, conversation: conversation, name: name))
        let title = String(localized: "home.chatColors.title", defaultValue: "Chat Colors", bundle: .module)
        panel.title = name.isEmpty ? title : "\(title) — \(name)"
        if !panel.isVisible, let frame = window?.frame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.midY - panel.frame.height / 2))
        }
        panel.makeKeyAndOrderFront(nil)
        host?.page?.focusPage()
    }

    /// Closes the panel (Done, Return, Escape, its close button); the page stays loaded for the next open.
    public func close() {
        releaseColorPanel()
        provider.end()
        panel?.orderOut(nil)
    }

    private func makePanel() -> HomeChatColorsWindow {
        let panel = HomeChatColorsWindow(contentRect: NSRect(origin: .zero, size: Self.size),
                                         styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        panel.delegate = panel
        panel.hidesOnDeactivate = true
        panel.setAccessibilityIdentifier("cmux.home.chatColors")
        panel.onClose = { [weak self] in
            self?.releaseColorPanel()
            self?.provider.end()
        }
        let host = HomeChatColorsHostView(frame: NSRect(origin: .zero, size: contentSize))
        host.onThemeChange = { [weak provider] in provider?.refresh() }
        if let page = PageWebView(descriptor: .homeChatColors, routes: [PageRoute(prefix: HomeChatColorsProvider.prefix, provider: provider)],
                                  options: Self.engineOptions) {
            host.install(page)
        }
        self.host = host
        panel.contentView = host
        panel.setContentSize(contentSize)
        followZoom()
        return panel
    }

    /// Resizes the panel when `app.uiScale` changes, as the page's zoom follows it. One loop for the
    /// app-lifetime panel; it ends with the service.
    private func followZoom() {
        // task-owner: one loop per panel, which lives as long as the service; ends when the service is gone
        zoomFollower = Task { [weak self] in
            for await _ in ObservationStream({ DesignSettings.shared.uiScale }) {
                guard let self, let panel = self.panel else { return }
                let size = self.contentSize
                if panel.contentView?.frame.size != size { panel.setContentSize(size) }
            }
        }
    }

    /// Opens the system colour panel beside this one, starting from `start`; each change is a pick for `role`.
    private func showColorPanel(for role: HomeChatColorsProvider.Role, from start: HomeColor) {
        let colors = NSColorPanel.shared
        colorBorrow = GroupColorPanel.shared.borrow(
            start: NSColor(srgbRed: start.red, green: start.green, blue: start.blue, alpha: 1), continuous: true,
            onPick: { [weak provider] color in provider?.pick(role, HomeColor(srgb: color)) },
            onEnd: { [weak self] in self?.colorPanelTaken() })
        if let panel {
            // Beside this panel unless it already sits here: a panel another part of the app had
            // open moves over too.
            if !colors.isVisible || colors.parent !== panel {
                colors.setFrameTopLeftPoint(NSPoint(x: panel.frame.maxX + 8, y: panel.frame.maxY))
            }
            // Attached: it moves with the panel and hides with it.
            if colors.parent == nil { panel.addChildWindow(colors, ordered: .above) }
        }
        colors.orderFront(nil)
    }

    /// Stops the colour panel picking for this chat, and closes it when this chat still has it.
    /// Once another part of the app borrowed it (a group editor's custom color) or the person
    /// closed it, the panel is theirs: it is left as it is.
    private func releaseColorPanel() {
        guard let borrow = colorBorrow else { return }
        colorBorrow = nil
        let colors = NSColorPanel.shared
        let held = GroupColorPanel.shared.holds(borrow)
        GroupColorPanel.shared.giveBack(borrow)
        detachColorPanel()
        if held, colors.isVisible { colors.orderOut(nil) }
    }

    /// Another part of the app borrowed the colour panel, or the person closed it: this chat's picks
    /// end, and the panel no longer moves or hides with this one.
    private func colorPanelTaken() {
        colorBorrow = nil
        detachColorPanel()
    }

    private func detachColorPanel() {
        let colors = NSColorPanel.shared
        if let panel, colors.parent === panel { panel.removeChildWindow(colors) }
    }
}

/// The Chat Colors panel: its close button and Escape end the session as Done does. It is its own
/// delegate, so every close (the button, Escape, `close()`) reaches `onClose` with no `close` override.
@MainActor
final class HomeChatColorsWindow: NSPanel, NSWindowDelegate {
    var onClose: (() -> Void)?

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    override func cancelOperation(_ sender: Any?) {
        close()
    }
}

/// The panel's content: the page, and the theme scope the preview resolves in. A theme or appearance
/// change sends the page its state again.
@MainActor
final class HomeChatColorsHostView: NSView {
    private(set) var page: PageWebView?
    var onThemeChange: (() -> Void)?

    func install(_ page: PageWebView) {
        page.frame = bounds
        page.autoresizingMask = [.width, .height]
        addSubview(page)
        self.page = page
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onThemeChange?()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onThemeChange?()
    }
}

extension HomeColor {
    /// The sRGB colour of `color` (opaque).
    init(srgb color: NSColor) {
        let s = color.usingColorSpace(.sRGB) ?? NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        self.init(red: s.redComponent, green: s.greenComponent, blue: s.blueComponent)
    }
}
