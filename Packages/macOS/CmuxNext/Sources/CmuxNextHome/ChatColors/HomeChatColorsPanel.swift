public import AppKit
import CmuxHomeRender
public import CmuxNextDesign

/// The Chat Colors… panel (a chat row's menu, the palette, `home.chatColors`): one small floating
/// panel for the app, showing one chat at a time; opening it for another chat switches it there.
@MainActor
public final class HomeChatColorsPanel {
    private let store: HomeChatColorStore
    private let design: DesignSettings
    private var panel: NSPanel?
    /// The panel, once shown (tests).
    var window: NSPanel? { panel }

    /// - Parameters:
    ///   - store: the chats' colours (the Home service's).
    ///   - design: the settings the bubble style and the default for every chat come from.
    public init(store: HomeChatColorStore, design: DesignSettings) {
        self.store = store
        self.design = design
    }

    /// Shows the panel for `conversation`, over `window` when there is one.
    /// - Parameters:
    ///   - conversation: the chat's conversation id.
    ///   - name: the chat's name, in the panel's title.
    ///   - window: the window it opens over.
    public func show(conversation: String, name: String, over window: NSWindow?) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let host = HomeChatColorsView(
            store: store, conversation: conversation,
            resolve: { [design] chosen in
                // The view calls this in its theme scope (performWithTheme).
                let style: HomePalette.BubbleStyle = design.homeChiefBubblesThemed ? .theme : .iMessage
                let all = HomeChatColorStore.colors(fromHexes: design.homeBubbleColors)
                return HomeChatColorsPreview(HomeThemePalette.resolveInScope(active: true, style: style).applying(chosen.over(all)))
            },
            onDone: { [weak panel] in panel?.orderOut(nil) })
        panel.contentView = host
        panel.title = name.isEmpty ? HomeChatColorsStrings.title : "\(HomeChatColorsStrings.title) — \(name)"
        panel.setContentSize(host.fittingSize)
        if !panel.isVisible, let frame = window?.frame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.midY - panel.frame.height / 2))
        }
        panel.makeKeyAndOrderFront(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 400),
                            styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        panel.setAccessibilityIdentifier("cmux.home.chatColors")
        return panel
    }
}
