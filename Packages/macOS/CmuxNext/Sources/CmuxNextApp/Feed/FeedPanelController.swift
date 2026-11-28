import AppKit
import CmuxNextDesign
import CmuxNextFeed

/// The feed panel (`feed.show`, ⇧⌘I; FD8: the list view by default, the inbox
/// view by the `feed.layout` tunable) at the top right of the active window.
/// It shows the `FeedService` mirror; answers and triage go out as intents
/// with origin user from the panel's own controls.
@MainActor
final class FeedPanelController {
    static let size = NSSize(width: 420, height: 560)

    private let context: AppActionContext
    private var panel: FeedPanel?

    init(context: AppActionContext) {
        self.context = context
    }

    var isShown: Bool { panel?.isVisible ?? false }

    func toggle() {
        if isShown { close() } else { show() }
    }

    private func show() {
        guard let window = context.services.windows.active?.window, case let feed = context.services.feed else { return }
        feed.startIfSignedIn()
        let panel = panel ?? makePanel(model: feed.model)
        self.panel = panel
        window.themeScope.adopt(panel)
        let content = window.contentLayoutRect
        let inset = Metrics.space3
        let origin = NSPoint(x: content.maxX - Self.size.width - inset, y: content.maxY - Self.size.height - inset)
        panel.setFrame(window.convertToScreen(NSRect(origin: origin, size: Self.size)), display: true)
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        panel.onResignKey = { [weak self] in self?.close(restoringKey: false) }
        panel.orderFront(nil)
        panel.makeKey()
    }

    func close(restoringKey: Bool = true) {
        guard let panel, panel.isVisible else { return }
        panel.onResignKey = nil
        if restoringKey, panel.isKeyWindow, let parent = panel.parent, parent.isVisible { parent.makeKey() }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    private func makePanel(model: FeedModel) -> FeedPanel {
        let panel = FeedPanel()
        panel.contentView = FeedHostView(model: model, floating: true)
        panel.onEscape = { [weak self] in self?.close() }
        return panel
    }
}

/// A non-activating, borderless child panel, like the notifications panel.
final class FeedPanel: ActiveAppKeyPanel {
    var onResignKey: (() -> Void)?
    var onEscape: (() -> Void)?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = true
        becomesKeyOnlyIfNeeded = false
        isMovable = false
        animationBehavior = .none
        isReleasedWhenClosed = false
        collectionBehavior = [.transient, .fullScreenAuxiliary, .ignoresCycle]
        setAccessibilityIdentifier("cmux.feed")
        setAccessibilityRole(.popover)
    }

    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}
