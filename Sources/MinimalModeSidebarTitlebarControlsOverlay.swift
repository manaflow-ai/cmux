import AppKit
import CmuxNotifications

@MainActor
final class MinimalModeSidebarTitlebarControlsOverlayView: NSView {
    private let controlsView: HiddenTitlebarSidebarControlsView
    private var leadingInset: CGFloat
    private var topInset: CGFloat

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        guard WorkspacePresentationModeSettings.isMinimal() else { return .zero }
        let controlsSize = controlsView.intrinsicContentSize
        return NSSize(
            width: leadingInset + controlsSize.width,
            height: topInset + controlsSize.height
        )
    }

    init(
        unreadModel: SidebarUnreadModel,
        layoutModel: TitlebarControlsLayoutModel,
        leadingInset: CGFloat,
        topInset: CGFloat,
        onToggleSidebar: @escaping () -> Void,
        onToggleNotifications: @escaping (NSView?) -> Void,
        onNewTab: @escaping () -> Void,
        onFocusHistoryBack: @escaping () -> Void,
        onFocusHistoryForward: @escaping () -> Void
    ) {
        self.leadingInset = leadingInset
        self.topInset = topInset
        controlsView = HiddenTitlebarSidebarControlsView(
            unreadModel: unreadModel,
            layoutModel: layoutModel,
            onToggleSidebar: onToggleSidebar,
            onToggleNotifications: onToggleNotifications,
            onNewTab: onNewTab,
            onFocusHistoryBack: onFocusHistoryBack,
            onFocusHistoryForward: onFocusHistoryForward
        )
        super.init(frame: .zero)

        addSubview(controlsView)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(defaultsDidChange(_:)),
            name: UserDefaults.didChangeNotification,
            object: UserDefaults.standard
        )
        refreshPresentationMode()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func update(
        leadingInset: CGFloat,
        topInset: CGFloat,
        onToggleSidebar: @escaping () -> Void,
        onToggleNotifications: @escaping (NSView?) -> Void,
        onNewTab: @escaping () -> Void,
        onFocusHistoryBack: @escaping () -> Void,
        onFocusHistoryForward: @escaping () -> Void
    ) {
        let geometryChanged = self.leadingInset != leadingInset || self.topInset != topInset
        self.leadingInset = leadingInset
        self.topInset = topInset
        controlsView.update(
            onToggleSidebar: onToggleSidebar,
            onToggleNotifications: onToggleNotifications,
            onNewTab: onNewTab,
            onFocusHistoryBack: onFocusHistoryBack,
            onFocusHistoryForward: onFocusHistoryForward
        )
        if geometryChanged {
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
        refreshPresentationMode()
    }

    override func layout() {
        super.layout()
        guard !controlsView.isHidden else {
            controlsView.frame = .zero
            return
        }
        controlsView.frame = NSRect(
            origin: NSPoint(x: leadingInset, y: topInset),
            size: controlsView.intrinsicContentSize
        )
    }

    @objc private func defaultsDidChange(_ notification: Notification) {
        refreshPresentationMode()
    }

    private func refreshPresentationMode() {
        let shouldShow = WorkspacePresentationModeSettings.isMinimal()
        guard controlsView.isHidden == shouldShow else { return }
        controlsView.isHidden = !shouldShow
        invalidateIntrinsicContentSize()
        needsLayout = true
    }
}
