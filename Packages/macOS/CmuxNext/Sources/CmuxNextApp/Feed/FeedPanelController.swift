import AppKit
import CmuxNextDesign

/// The feed panel (`feed.show`, ⇧⌘I) at the top right of the active window: the Feed page's
/// list (`#/list?surface=panel`). Answers and triage go to the daemon's feed client from the
/// page's own controls; Esc closes the panel.
@MainActor
final class FeedPanelController {
    static let size = NSSize(width: 420, height: 560)

    private let context: AppActionContext
    private var panel: FeedPanel?
    private let motion = CornerPanelMotion()

    init(context: AppActionContext) {
        self.context = context
    }

    var isShown: Bool { (panel?.isVisible ?? false) && !motion.isClosing }

    func toggle() {
        if isShown { close() } else { show() }
    }

    private func show() {
        guard let window = context.services.windows.active?.window else { return }
        let panel = panel ?? makePanel()
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
        motion.open(panel)
        panel.makeKey()
    }

    func close(restoringKey: Bool = true) {
        guard let panel, isShown else { return }
        panel.onResignKey = nil
        if restoringKey, panel.isKeyWindow, let parent = panel.parent, parent.isVisible { parent.makeKey() }
        motion.close(panel) { [weak panel] in
            guard let panel else { return }
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
    }

    private func makePanel() -> FeedPanel {
        let panel = FeedPanel()
        panel.contentView = PageFactory(services: context.services).feedWebPage(route: "#/list?surface=panel") ?? NSView()
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
