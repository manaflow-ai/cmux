import AppKit
import Bonsplit
import Combine
import SwiftUI


// MARK: - Titlebar controls accessory view controller
final class NonDraggableHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { false }
}

struct TitlebarControlsLayoutSnapshot: Equatable {
    let contentSize: NSSize
    let containerHeight: CGFloat
    let xOffset: CGFloat
    let yOffset: CGFloat
}

func titlebarControlsShouldTrackButtonHover(config: TitlebarControlsStyleConfig) -> Bool {
    true
}

func titlebarControlsShouldScheduleForViewSizeChange(
    previous: NSSize,
    current: NSSize,
    tolerance: CGFloat = 0.5
) -> Bool {
    guard current.width > 0, current.height > 0 else { return false }
    guard previous.width > 0, previous.height > 0 else { return true }
    return abs(previous.width - current.width) > tolerance
        || abs(previous.height - current.height) > tolerance
}

func titlebarControlsShouldApplyLayout(
    previous: TitlebarControlsLayoutSnapshot?,
    next: TitlebarControlsLayoutSnapshot,
    tolerance: CGFloat = 0.5
) -> Bool {
    guard let previous else { return true }
    return abs(previous.contentSize.width - next.contentSize.width) > tolerance
        || abs(previous.contentSize.height - next.contentSize.height) > tolerance
        || abs(previous.containerHeight - next.containerHeight) > tolerance
        || abs(previous.xOffset - next.xOffset) > tolerance
        || abs(previous.yOffset - next.yOffset) > tolerance
}

enum TitlebarWindowGeometryNotifications {
    static let names: [Notification.Name] = [
        NSWindow.didResizeNotification,
        NSWindow.didEndLiveResizeNotification,
        NSWindow.willEnterFullScreenNotification,
        NSWindow.didEnterFullScreenNotification,
        NSWindow.willExitFullScreenNotification,
        NSWindow.didExitFullScreenNotification,
        NSWindow.didChangeScreenNotification,
        NSWindow.didChangeBackingPropertiesNotification
    ]
}

final class TitlebarControlsAccessoryViewController: NSTitlebarAccessoryViewController, NSPopoverDelegate {
    private let hostingView: NonDraggableHostingView<TitlebarControlsView>
    private let containerView: NSView
    private let notificationStore: TerminalNotificationStore
    private lazy var notificationsPopover: NSPopover = makeNotificationsPopover()
    private var pendingSizeUpdate = false
    private var intrinsicSizeNeedsRefresh = true
    private var cachedContentSize: NSSize?
    private var lastObservedViewSize: NSSize = .zero
    private var lastAppliedLayoutSnapshot: TitlebarControlsLayoutSnapshot?
    private weak var observedWindow: NSWindow?
    private var windowGeometryObservers: [NSObjectProtocol] = []
    private let viewModel = TitlebarControlsViewModel()
    private var userDefaultsObserver: NSObjectProtocol?
    var popoverIsShownForTesting: Bool { notificationsPopover.isShown }
    private var showsWorkspaceTitlebar: Bool { !WorkspacePresentationModeSettings.isMinimal() }

    init(notificationStore: TerminalNotificationStore) {
        let containerView = NSView()
        self.containerView = containerView
        self.notificationStore = notificationStore
        let toggleSidebar = { [weak containerView] in
            _ = AppDelegate.shared?.toggleSidebarInActiveMainWindow(preferredWindow: containerView?.window)
        }
        let toggleNotifications: () -> Void = { [weak containerView] in
            _ = AppDelegate.shared?.toggleNotificationsPopover(animated: true, anchorView: containerView)
        }
        let newTab = { _ = AppDelegate.shared?.performNewWorkspaceAction(debugSource: "titlebar.accessoryNewWorkspace") }
        let focusHistoryBack = { [weak containerView] in
            _ = AppDelegate.shared?.activeTabManagerForCommands(preferredWindow: containerView?.window)?.navigateBack()
        }
        let focusHistoryForward = { [weak containerView] in
            _ = AppDelegate.shared?.activeTabManagerForCommands(preferredWindow: containerView?.window)?.navigateForward()
        }
        hostingView = NonDraggableHostingView(
            rootView: TitlebarControlsView(
                notificationStore: notificationStore,
                viewModel: viewModel,
                onToggleSidebar: toggleSidebar,
                onToggleNotifications: toggleNotifications,
                onNewTab: newTab,
                onFocusHistoryBack: focusHistoryBack,
                onFocusHistoryForward: focusHistoryForward,
                visibilityMode: .alwaysVisible
            )
        )

        super.init(nibName: nil, bundle: nil)

        view = containerView
        containerView.translatesAutoresizingMaskIntoConstraints = true
        // The shortcut-hint pills (and button backgrounds) sit below the button
        // row and overflow the accessory's titlebar-height content frame on
        // purpose. macOS 26.5 began re-deriving `layer.masksToBounds` from the
        // AppKit `clipsToBounds` property on every layout pass, which clobbered
        // a bare `layer?.masksToBounds = false` write and re-clipped that
        // overflow (the hint captions got cut off at the bottom). Set
        // `clipsToBounds = false` on both the container and the hosting view so
        // the non-clipping intent persists across layout on every macOS version.
        containerView.wantsLayer = true
        containerView.clipsToBounds = false
        containerView.layer?.masksToBounds = false
        hostingView.translatesAutoresizingMaskIntoConstraints = true
        hostingView.autoresizingMask = []
        hostingView.clipsToBounds = false
        hostingView.layer?.masksToBounds = false
        containerView.addSubview(hostingView)

        userDefaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyWorkspaceTitlebarVisibility()
            if self?.showsWorkspaceTitlebar == true {
                self?.restoreSizeAfterMinimalMode()
                self?.scheduleSizeUpdate()
            }
        }

        applyWorkspaceTitlebarVisibility()
        scheduleSizeUpdate(invalidateIntrinsicSize: true)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let userDefaultsObserver {
            NotificationCenter.default.removeObserver(userDefaultsObserver)
        }
        removeWindowGeometryObservers()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        updateObservedWindowIfNeeded()
        scheduleSizeUpdate(invalidateIntrinsicSize: true)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let observedWindowChanged = updateObservedWindowIfNeeded()
        let currentViewSize = view.bounds.size
        guard titlebarControlsShouldScheduleForViewSizeChange(
            previous: lastObservedViewSize,
            current: currentViewSize
        ) || observedWindowChanged else {
            return
        }
        lastObservedViewSize = currentViewSize
        scheduleSizeUpdate(invalidateIntrinsicSize: true, invalidateLayout: observedWindowChanged)
    }

    @discardableResult
    private func updateObservedWindowIfNeeded() -> Bool {
        let currentWindow = view.window
        guard currentWindow !== observedWindow else { return false }
        removeWindowGeometryObservers()
        observedWindow = currentWindow
        guard let currentWindow else { return true }
        let center = NotificationCenter.default
        windowGeometryObservers = TitlebarWindowGeometryNotifications.names.map { name in
            center.addObserver(forName: name, object: currentWindow, queue: .main) { [weak self] _ in
                self?.scheduleSizeUpdate(invalidateIntrinsicSize: true, invalidateLayout: true)
            }
        }
        return true
    }

    private func removeWindowGeometryObservers() {
        let center = NotificationCenter.default
        for observer in windowGeometryObservers {
            center.removeObserver(observer)
        }
        windowGeometryObservers.removeAll()
    }

    private func scheduleSizeUpdate(
        invalidateIntrinsicSize: Bool = false,
        invalidateLayout: Bool = false
    ) {
        updateObservedWindowIfNeeded()
        if invalidateLayout {
            lastAppliedLayoutSnapshot = nil
        }
        if invalidateIntrinsicSize {
            intrinsicSizeNeedsRefresh = true
        }
        guard !pendingSizeUpdate else { return }
        pendingSizeUpdate = true
        DispatchQueue.main.async { [weak self] in
            self?.pendingSizeUpdate = false
            self?.updateSize()
        }
    }

    private func updateSize() {
        updateObservedWindowIfNeeded()
        applyWorkspaceTitlebarVisibility()
        guard showsWorkspaceTitlebar else { return }
        let styleRawValue = UserDefaults.standard.integer(forKey: "titlebarControlsStyle")
        let style = TitlebarControlsStyle(rawValue: styleRawValue) ?? .classic
        let contentSize = TitlebarControlsLayoutMetrics.contentSize(config: style.config)
        if intrinsicSizeNeedsRefresh {
            hostingView.invalidateIntrinsicContentSize()
            intrinsicSizeNeedsRefresh = false
        }
        cachedContentSize = contentSize

        guard contentSize.width > 0, contentSize.height > 0 else { return }
        let closeButton = view.window?.standardWindowButton(.closeButton)
        let titlebarView = closeButton?.superview
        let trafficLightFrame = closeButton.map { button in
            view.convert(button.convert(button.bounds, to: nil), from: nil)
        }
#if DEBUG
        TitlebarChromeUITestRecorder.recordTrafficLightFrames(window: view.window)
#endif
        let titlebarHeight = (titlebarView?.frame.height ?? 0) > 0
            ? titlebarView?.frame.height ?? contentSize.height
            : view.window.map { window in
                window.frame.height - window.contentLayoutRect.height
            } ?? contentSize.height
        let containerHeight = TitlebarControlsLayoutMetrics.containerHeight(
            contentHeight: contentSize.height,
            titlebarHeight: titlebarHeight
        )
        let debugSnapshot = MinimalModeTitlebarDebugSettings.snapshot()
        let xOffset = TitlebarControlsLayoutMetrics.leadingOffset(
            trafficLightFrame: trafficLightFrame,
            debugSnapshot: debugSnapshot
        )
        let yOffset = TitlebarControlsLayoutMetrics.yOffset(
            contentHeight: contentSize.height,
            containerHeight: containerHeight,
            trafficLightFrame: trafficLightFrame,
            debugSnapshot: debugSnapshot
        )
        let nextLayoutSnapshot = TitlebarControlsLayoutSnapshot(
            contentSize: contentSize,
            containerHeight: containerHeight,
            xOffset: xOffset,
            yOffset: yOffset
        )
        guard titlebarControlsShouldApplyLayout(
            previous: lastAppliedLayoutSnapshot,
            next: nextLayoutSnapshot
        ) else {
            return
        }
        lastAppliedLayoutSnapshot = nextLayoutSnapshot
        let containerWidth = contentSize.width + abs(xOffset)
        preferredContentSize = NSSize(width: containerWidth, height: containerHeight)
        containerView.setFrameSize(NSSize(width: containerWidth, height: containerHeight))
        hostingView.frame = NSRect(x: xOffset, y: yOffset, width: contentSize.width, height: contentSize.height)
    }

    private func applyWorkspaceTitlebarVisibility() {
        let shouldShow = showsWorkspaceTitlebar
        self.isHidden = !shouldShow
        view.isHidden = !shouldShow
        view.alphaValue = shouldShow ? 1 : 0
        if !shouldShow {
            preferredContentSize = .zero
        }
    }

    /// Restore the accessory size after it was zeroed in minimal mode.
    /// Seeds the hosting view with a non-zero frame before deterministic sizing
    /// runs again after the view was collapsed.
    private func restoreSizeAfterMinimalMode() {
        guard showsWorkspaceTitlebar else { return }
        let seed = cachedContentSize ?? NSSize(width: 200, height: 28)
        if hostingView.frame.size == .zero || containerView.frame.size == .zero {
            containerView.frame.size = seed
            hostingView.frame.size = seed
        }
        scheduleSizeUpdate(invalidateIntrinsicSize: true)
    }

    func toggleNotificationsPopover(animated: Bool = true, externalAnchor: NSView? = nil) {
        if notificationsPopover.isShown {
            notificationsPopover.animates = animated
            notificationsPopover.performClose(nil)
            return
        }
        // Recreate content view each time to avoid stale observers when popover is hidden
        let hostingController = NSHostingController(
            rootView: NotificationsPopoverView(
                notificationStore: notificationStore,
                onDismiss: { [weak notificationsPopover] in
                    notificationsPopover?.performClose(nil)
                }
            )
        )
        hostingController.view.wantsLayer = true
        hostingController.view.layer?.backgroundColor = .clear
        notificationsPopover.contentViewController = hostingController

        guard let window = externalAnchor?.window ?? view.window ?? hostingView.window ?? NSApp.keyWindow,
              let contentView = window.contentView else {
            return
        }

        // Force layout to ensure geometry is current.
        contentView.layoutSubtreeIfNeeded()

        // Use external anchor (e.g. fullscreen sidebar controls) if provided.
        if let externalAnchor, externalAnchor.window != nil {
            let anchorView = preferredNotificationsPopoverAnchor(
                buttonAnchor: viewModel.notificationsAnchorView,
                fallbackAnchor: externalAnchor
            ) ?? externalAnchor
            let anchorContentView = anchorView.window?.contentView ?? contentView
            anchorContentView.layoutSubtreeIfNeeded()
            anchorView.superview?.layoutSubtreeIfNeeded()
            let anchorRect = anchorView.convert(anchorView.bounds, to: anchorContentView)
            if !anchorRect.isEmpty {
                notificationsPopover.animates = animated
                notificationsPopover.show(relativeTo: anchorRect, of: anchorContentView, preferredEdge: .maxY)
                postNotificationsPopoverVisibilityDidChange(
                    isShown: true,
                    source: notificationsPopover,
                    windowNumber: anchorView.window?.windowNumber ?? window.windowNumber
                )
                return
            }
        }

        if let anchorView = viewModel.notificationsAnchorView, anchorView.window != nil, !isHidden {
            anchorView.superview?.layoutSubtreeIfNeeded()
            let anchorRect = anchorView.convert(anchorView.bounds, to: contentView)
            if !anchorRect.isEmpty {
                notificationsPopover.animates = animated
                notificationsPopover.show(relativeTo: anchorRect, of: contentView, preferredEdge: .maxY)
                postNotificationsPopoverVisibilityDidChange(
                    isShown: true,
                    source: notificationsPopover,
                    windowNumber: window.windowNumber
                )
                return
            }
        }

        // Fallback: position near top-left of the window content.
        let bounds = contentView.bounds
        let anchorRect = NSRect(x: 12, y: bounds.maxY - 8, width: 1, height: 1)
        notificationsPopover.animates = animated
        notificationsPopover.show(relativeTo: anchorRect, of: contentView, preferredEdge: .maxY)
        postNotificationsPopoverVisibilityDidChange(
            isShown: true,
            source: notificationsPopover,
            windowNumber: window.windowNumber
        )
    }

    func dismissNotificationsPopover() {
        if notificationsPopover.isShown {
            notificationsPopover.performClose(nil)
        }
    }

    private func makeNotificationsPopover() -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .semitransient
        popover.animates = true
        popover.delegate = self
        // Content view controller is set dynamically in toggleNotificationsPopover
        return popover
    }

    // MARK: - NSPopoverDelegate

    func popoverDidClose(_ notification: Notification) {
        // Clear the content view controller to stop SwiftUI observers when popover is hidden
        notificationsPopover.contentViewController = nil
        postNotificationsPopoverVisibilityDidChange(isShown: false, source: notificationsPopover)
    }
}

