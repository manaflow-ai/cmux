public import AppKit
import CmuxHomeRender
public import CmuxNextDesign
public import CmuxNextPages

/// The Chat Colors… panel (a chat row's menu, the palette, `home.chatColors`): one small floating
/// panel for the app, showing one chat at a time; opening it for another chat switches it there.
/// The content is the React page (webviews/src/pages/home-chat-colors), loaded once into one
/// ``PageWebView`` and reused for every open, as the icon picker does (``IconPickerService``).
/// Custom Color opens the system colour panel, attached to this panel; its picks go through the
/// same store path as a swatch and stream back to the page as state.
@MainActor
public final class HomeChatColorsService {
    /// 340 pt wide; the page's fixed layout is 340 pt high (webviews/src/pages/home-chat-colors/styles.css).
    static let size = NSSize(width: 340, height: 340)
    /// A titled, opaque utility panel: Chromium can host the page (no see-through overlay).
    public static let engineOptions = PageEngineOptions.standard

    let provider: HomeChatColorsProvider
    private var panel: HomeChatColorsWindow?
    private var host: HomeChatColorsHostView?
    private let colorTarget = HomeChatColorsColorTarget()
    /// Whether the system colour panel is ours now (Custom Color opened it and the panel is open).
    private var ownsColorPanel = false

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
        panel.hidesOnDeactivate = true
        panel.setAccessibilityIdentifier("cmux.home.chatColors")
        panel.onClose = { [weak self] in
            self?.releaseColorPanel()
            self?.provider.end()
        }
        let host = HomeChatColorsHostView(frame: NSRect(origin: .zero, size: Self.size))
        host.onThemeChange = { [weak provider] in provider?.refresh() }
        if let page = PageWebView(descriptor: .homeChatColors, routes: [PageRoute(prefix: HomeChatColorsProvider.prefix, provider: provider)],
                                  options: Self.engineOptions) {
            host.install(page)
        }
        self.host = host
        panel.contentView = host
        panel.setContentSize(Self.size)
        return panel
    }

    /// Opens the system colour panel beside this one, starting from `start`; each change is a pick for `role`.
    private func showColorPanel(for role: HomeChatColorsProvider.Role, from start: HomeColor) {
        let colors = NSColorPanel.shared
        // The start colour is set with no target, so setting it is not a pick.
        colors.setTarget(nil)
        colors.setAction(nil)
        colors.showsAlpha = false
        colors.isContinuous = true
        colors.color = NSColor(srgbRed: start.red, green: start.green, blue: start.blue, alpha: 1)
        colorTarget.onPick = { [weak provider] color in provider?.pick(role, HomeColor(srgb: color)) }
        colors.setTarget(colorTarget)
        colors.setAction(#selector(HomeChatColorsColorTarget.changed(_:)))
        ownsColorPanel = true
        if let panel {
            if !colors.isVisible { colors.setFrameTopLeftPoint(NSPoint(x: panel.frame.maxX + 8, y: panel.frame.maxY)) }
            // Attached: it moves with the panel and hides with it.
            if colors.parent == nil { panel.addChildWindow(colors, ordered: .above) }
        }
        colors.orderFront(nil)
    }

    /// Stops the colour panel picking for this chat, and closes it when Custom Color opened it.
    private func releaseColorPanel() {
        guard ownsColorPanel else { return }
        ownsColorPanel = false
        colorTarget.onPick = nil
        let colors = NSColorPanel.shared
        colors.setTarget(nil)
        colors.setAction(nil)
        if colors.parent === panel { panel?.removeChildWindow(colors) }
        colors.orderOut(nil)
    }
}

/// The Chat Colors panel: its close button and Escape end the session as Done does.
@MainActor
final class HomeChatColorsWindow: NSPanel {
    var onClose: (() -> Void)?

    override func close() {
        onClose?()
        super.close()
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

/// The system colour panel's target while Custom Color is open.
@MainActor
final class HomeChatColorsColorTarget: NSObject {
    var onPick: ((NSColor) -> Void)?

    @objc func changed(_ sender: NSColorPanel) {
        onPick?(sender.color)
    }
}

extension HomeColor {
    /// The sRGB colour of `color` (opaque).
    init(srgb color: NSColor) {
        let s = color.usingColorSpace(.sRGB) ?? NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        self.init(red: s.redComponent, green: s.greenComponent, blue: s.blueComponent)
    }
}
