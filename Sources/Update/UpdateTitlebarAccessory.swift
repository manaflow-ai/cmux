import AppKit
import Bonsplit
import Combine
import SwiftUI

final class NonDraggableHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { false }
}

enum TitlebarControlsStyle: Int, CaseIterable, Identifiable {
    case classic
    case compact
    case roomy
    case pillGroup
    case softButtons

    var id: Int { rawValue }

    var menuTitle: String {
        switch self {
        case .classic:
            return "Classic"
        case .compact:
            return "Compact"
        case .roomy:
            return "Roomy"
        case .pillGroup:
            return "Pill Group"
        case .softButtons:
            return "Soft Buttons"
        }
    }

    var config: TitlebarControlsStyleConfig {
        switch self {
        case .classic:
            return TitlebarControlsStyleConfig(
                spacing: 10,
                iconSize: 15,
                buttonSize: 24,
                badgeSize: 14,
                badgeOffset: CGSize(width: 2, height: -2),
                groupBackground: false,
                groupPadding: EdgeInsets(),
                buttonBackground: false,
                buttonCornerRadius: 8,
                hoverBackground: false
            )
        case .compact:
            return TitlebarControlsStyleConfig(
                spacing: 6,
                iconSize: 13,
                buttonSize: 20,
                badgeSize: 12,
                badgeOffset: CGSize(width: 1, height: -1),
                groupBackground: false,
                groupPadding: EdgeInsets(),
                buttonBackground: false,
                buttonCornerRadius: 6,
                hoverBackground: false
            )
        case .roomy:
            return TitlebarControlsStyleConfig(
                spacing: 14,
                iconSize: 16,
                buttonSize: 28,
                badgeSize: 16,
                badgeOffset: CGSize(width: 3, height: -3),
                groupBackground: false,
                groupPadding: EdgeInsets(),
                buttonBackground: false,
                buttonCornerRadius: 10,
                hoverBackground: false
            )
        case .pillGroup:
            return TitlebarControlsStyleConfig(
                spacing: 8,
                iconSize: 14,
                buttonSize: 24,
                badgeSize: 14,
                badgeOffset: CGSize(width: 2, height: -2),
                groupBackground: false,
                groupPadding: EdgeInsets(top: 1, leading: 4, bottom: 1, trailing: 4),
                buttonBackground: false,
                buttonCornerRadius: 8,
                hoverBackground: true
            )
        case .softButtons:
            return TitlebarControlsStyleConfig(
                spacing: 8,
                iconSize: 15,
                buttonSize: 26,
                badgeSize: 14,
                badgeOffset: CGSize(width: 2, height: -2),
                groupBackground: false,
                groupPadding: EdgeInsets(),
                buttonBackground: true,
                buttonCornerRadius: 8,
                hoverBackground: false
            )
        }
    }
}

struct TitlebarControlsStyleConfig {
    let spacing: CGFloat
    let iconSize: CGFloat
    let buttonSize: CGFloat
    let badgeSize: CGFloat
    let badgeOffset: CGSize
    let groupBackground: Bool
    let groupPadding: EdgeInsets
    let buttonBackground: Bool
    let buttonCornerRadius: CGFloat
    let hoverBackground: Bool
}

final class TitlebarControlsViewModel: ObservableObject {
    weak var notificationsAnchorView: NSView?
}

private struct NotificationsAnchorView: NSViewRepresentable {
    let onResolve: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = AnchorNSView()
        view.onLayout = { [weak view] in
            guard let view else { return }
            onResolve(view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class AnchorNSView: NSView {
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }
}

struct ShortcutHintLanePlanner {
    static func assignLanes(for intervals: [ClosedRange<CGFloat>], minSpacing: CGFloat = 4) -> [Int] {
        guard !intervals.isEmpty else { return [] }

        var laneMaxX: [CGFloat] = []
        var lanes: [Int] = []
        lanes.reserveCapacity(intervals.count)

        for interval in intervals {
            var lane = 0
            while lane < laneMaxX.count {
                let requiredMinX = laneMaxX[lane] + minSpacing
                if interval.lowerBound >= requiredMinX {
                    break
                }
                lane += 1
            }

            if lane == laneMaxX.count {
                laneMaxX.append(interval.upperBound)
            } else {
                laneMaxX[lane] = max(laneMaxX[lane], interval.upperBound)
            }
            lanes.append(lane)
        }

        return lanes
    }
}

struct ShortcutHintHorizontalPlanner {
    static func assignRightEdges(for intervals: [ClosedRange<CGFloat>], minSpacing: CGFloat = 6) -> [CGFloat] {
        guard !intervals.isEmpty else { return [] }

        var assignedRightEdges = Array(repeating: CGFloat.zero, count: intervals.count)
        var nextMaxRight = CGFloat.greatestFiniteMagnitude

        for index in stride(from: intervals.count - 1, through: 0, by: -1) {
            let interval = intervals[index]
            let width = interval.upperBound - interval.lowerBound
            let preferredRightEdge = interval.upperBound
            let adjustedRightEdge = min(preferredRightEdge, nextMaxRight)
            assignedRightEdges[index] = adjustedRightEdge
            nextMaxRight = adjustedRightEdge - width - minSpacing
        }

        return assignedRightEdges
    }
}

private struct TitlebarControlButton<Content: View>: View {
    let config: TitlebarControlsStyleConfig
    let action: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            content()
                .frame(width: config.buttonSize, height: config.buttonSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: config.buttonSize, height: config.buttonSize)
        .contentShape(Rectangle())
        .background(hoverBackground)
        .onHover { isHovering = $0 }
    }

    @ViewBuilder
    private var hoverBackground: some View {
        if config.hoverBackground && isHovering {
            RoundedRectangle(cornerRadius: config.buttonCornerRadius, style: .continuous)
                .fill(Color.primary.opacity(0.08))
        }
    }
}

private struct TitlebarControlsView: View {
    @ObservedObject var notificationStore: TerminalNotificationStore
    @ObservedObject var viewModel: TitlebarControlsViewModel
    let onToggleSidebar: () -> Void
    let onToggleNotifications: () -> Void
    let onNewTab: () -> Void
    @AppStorage("titlebarControlsStyle") private var styleRawValue = TitlebarControlsStyle.classic.rawValue
    @AppStorage(ShortcutHintDebugSettings.titlebarHintXKey) private var titlebarShortcutHintXOffset = ShortcutHintDebugSettings.defaultTitlebarHintX
    @AppStorage(ShortcutHintDebugSettings.titlebarHintYKey) private var titlebarShortcutHintYOffset = ShortcutHintDebugSettings.defaultTitlebarHintY
    @AppStorage(ShortcutHintDebugSettings.alwaysShowHintsKey) private var alwaysShowShortcutHints = ShortcutHintDebugSettings.defaultAlwaysShowHints
    @State private var shortcutRefreshTick = 0
    @StateObject private var commandKeyMonitor = TitlebarCommandKeyMonitor()
    private let titlebarHintRightSafetyShift: CGFloat = 10
    private let titlebarHintBaseXShift: CGFloat = -10
    private let titlebarHintBaseYShift: CGFloat = 1

    private enum HintSlot: Int, CaseIterable {
        case toggleSidebar
        case showNotifications
        case newTab

        var action: KeyboardShortcutSettings.Action {
            switch self {
            case .toggleSidebar:
                return .toggleSidebar
            case .showNotifications:
                return .showNotifications
            case .newTab:
                return .newTab
            }
        }
    }

    private struct TitlebarHintLayoutItem: Identifiable {
        let action: KeyboardShortcutSettings.Action
        let shortcut: StoredShortcut
        let width: CGFloat
        let leftEdge: CGFloat

        var id: String { action.rawValue }
    }

    private var shouldShowTitlebarShortcutHints: Bool {
        alwaysShowShortcutHints || commandKeyMonitor.isCommandPressed
    }

    var body: some View {
        // Force the `.help(...)` tooltips to re-evaluate when shortcuts are changed in settings.
        // (The titlebar controls don't otherwise re-render on UserDefaults changes.)
        let _ = shortcutRefreshTick
        let style = TitlebarControlsStyle(rawValue: styleRawValue) ?? .classic
        let config = style.config
        controlsGroup(config: config)
            .padding(.leading, 4)
            .padding(.trailing, titlebarHintTrailingInset)
            .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
                shortcutRefreshTick &+= 1
            }
            .onAppear {
                commandKeyMonitor.start()
            }
            .onDisappear {
                commandKeyMonitor.stop()
            }
    }

    private var titlebarHintTrailingInset: CGFloat {
        // Keep room for blur + shadow so the rightmost hint never clips.
        max(0, ShortcutHintDebugSettings.clamped(titlebarShortcutHintXOffset)) + titlebarHintRightSafetyShift + 8
    }

    private func titlebarHintVerticalBaseOffset(for config: TitlebarControlsStyleConfig) -> CGFloat {
        max(8, config.buttonSize * 0.4)
    }

    @ViewBuilder
    private func controlsGroup(config: TitlebarControlsStyleConfig) -> some View {
        let hintLayoutItems = titlebarHintLayoutItems(config: config)
        let content = HStack(spacing: config.spacing) {
            TitlebarControlButton(config: config, action: {
                #if DEBUG
                dlog("titlebar.toggleSidebar")
                #endif
                onToggleSidebar()
            }) {
                iconLabel(systemName: "sidebar.left", config: config)
            }
            .accessibilityIdentifier("titlebarControl.toggleSidebar")
            .accessibilityLabel("Toggle Sidebar")
            .help(KeyboardShortcutSettings.Action.toggleSidebar.tooltip("Show or hide the sidebar"))

            TitlebarControlButton(config: config, action: {
                #if DEBUG
                dlog("titlebar.notifications")
                #endif
                onToggleNotifications()
            }) {
                ZStack(alignment: .topTrailing) {
                    iconLabel(systemName: "bell", config: config)

                    if notificationStore.unreadCount > 0 {
                        Text("\(min(notificationStore.unreadCount, 99))")
                            .font(.system(size: max(8, config.badgeSize - 5), weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: config.badgeSize, height: config.badgeSize)
                            .background(
                                Circle().fill(Color.accentColor)
                            )
                            .offset(x: config.badgeOffset.width, y: config.badgeOffset.height)
                    }
                }
                .frame(width: config.buttonSize, height: config.buttonSize)
            }
            .accessibilityIdentifier("titlebarControl.showNotifications")
            .overlay(NotificationsAnchorView { viewModel.notificationsAnchorView = $0 }.allowsHitTesting(false))
            .accessibilityLabel("Notifications")
            .help(KeyboardShortcutSettings.Action.showNotifications.tooltip("Show notifications"))

            TitlebarControlButton(config: config, action: {
                #if DEBUG
                dlog("titlebar.newTab")
                #endif
                onNewTab()
            }) {
                iconLabel(systemName: "plus", config: config)
            }
            .accessibilityIdentifier("titlebarControl.newTab")
            .accessibilityLabel("New Workspace")
            .help(KeyboardShortcutSettings.Action.newTab.tooltip("New workspace"))
        }

        let paddedContent = content.padding(config.groupPadding)

        if config.groupBackground {
            paddedContent
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1)
                )
                .overlay(alignment: .topLeading) {
                    titlebarShortcutHintOverlay(items: hintLayoutItems, config: config)
                }
        } else {
            paddedContent
                .overlay(alignment: .topLeading) {
                    titlebarShortcutHintOverlay(items: hintLayoutItems, config: config)
                }
        }
    }

    private func titlebarHintLayoutItems(config: TitlebarControlsStyleConfig) -> [TitlebarHintLayoutItem] {
        let xOffset = CGFloat(ShortcutHintDebugSettings.clamped(titlebarShortcutHintXOffset))
        let intervals = titlebarHintIntervals(config: config, xOffset: xOffset)
        guard !intervals.isEmpty else { return [] }

        // Keep all titlebar hints on the same Y lane and resolve overlaps by shifting left.
        let minimumSpacing: CGFloat = 6
        let assignedRightEdges = ShortcutHintHorizontalPlanner.assignRightEdges(
            for: intervals.map { $0.interval },
            minSpacing: minimumSpacing
        )

        var items: [TitlebarHintLayoutItem] = []
        items.reserveCapacity(intervals.count)
        for (index, item) in intervals.enumerated() {
            let rightEdge = assignedRightEdges[index]
            items.append(
                TitlebarHintLayoutItem(
                    action: item.action,
                    shortcut: item.shortcut,
                    width: item.width,
                    leftEdge: rightEdge - item.width
                )
            )
        }
        return items
    }

    private func titlebarHintIntervals(
        config: TitlebarControlsStyleConfig,
        xOffset: CGFloat
    ) -> [(action: KeyboardShortcutSettings.Action, shortcut: StoredShortcut, width: CGFloat, interval: ClosedRange<CGFloat>)] {
        guard shouldShowTitlebarShortcutHints else { return [] }

        return HintSlot.allCases.compactMap { slot in
            let shortcut = KeyboardShortcutSettings.shortcut(for: slot.action)
            guard shortcut.command else { return nil }

            let width = titlebarHintWidth(for: shortcut, config: config)
            let rightEdge = config.groupPadding.leading
                + titlebarButtonRightEdge(for: slot, config: config)
                + xOffset
                + titlebarHintRightSafetyShift
                + titlebarHintBaseXShift
            return (slot.action, shortcut, width, (rightEdge - width)...rightEdge)
        }
    }

    private func titlebarHintWidth(for shortcut: StoredShortcut, config: TitlebarControlsStyleConfig) -> CGFloat {
        let font = NSFont.systemFont(ofSize: max(8, config.iconSize - 4), weight: .semibold)
        let textWidth = (shortcut.displayString as NSString).size(withAttributes: [.font: font]).width
        return ceil(textWidth) + 12
    }

    private func titlebarButtonRightEdge(for slot: HintSlot, config: TitlebarControlsStyleConfig) -> CGFloat {
        let index = CGFloat(slot.rawValue)
        return (index + 1) * config.buttonSize + index * config.spacing
    }

    @ViewBuilder
    private func titlebarShortcutHintOverlay(
        items: [TitlebarHintLayoutItem],
        config: TitlebarControlsStyleConfig
    ) -> some View {
        let yOffset = config.groupPadding.top
            + titlebarHintVerticalBaseOffset(for: config)
            + titlebarHintBaseYShift
            + ShortcutHintDebugSettings.clamped(titlebarShortcutHintYOffset)

        ZStack(alignment: .topLeading) {
            ForEach(items) { item in
                titlebarShortcutHintPill(shortcut: item.shortcut, config: config)
                    .accessibilityIdentifier("titlebarShortcutHint.\(item.action.rawValue)")
                    .frame(width: item.width, alignment: .leading)
                    .offset(x: item.leftEdge, y: yOffset)
            }
        }
        .animation(.easeInOut(duration: 0.14), value: shouldShowTitlebarShortcutHints)
        .transition(.opacity)
        .allowsHitTesting(false)
    }

    private func titlebarShortcutHintPill(
        shortcut: StoredShortcut,
        config: TitlebarControlsStyleConfig
    ) -> some View {
        Text(shortcut.displayString)
            .font(.system(size: max(8, config.iconSize - 5), weight: .semibold, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundColor(.primary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .frame(minHeight: max(14, config.iconSize + 1))
            .background(ShortcutHintPillBackground())
    }

    @ViewBuilder
    private func iconLabel(systemName: String, config: TitlebarControlsStyleConfig) -> some View {
        let icon = Image(systemName: systemName)
            .font(.system(size: config.iconSize, weight: .semibold))
            .frame(width: config.buttonSize, height: config.buttonSize)

        if config.buttonBackground {
            icon
                .background(
                    RoundedRectangle(cornerRadius: config.buttonCornerRadius)
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.7))
                )
        } else {
            icon
        }
    }
}

@MainActor
private final class TitlebarCommandKeyMonitor: ObservableObject {
    @Published private(set) var isCommandPressed = false

    private var flagsMonitor: Any?
    private var keyDownMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var pendingShowWorkItem: DispatchWorkItem?

    func start() {
        guard flagsMonitor == nil else {
            update(from: NSEvent.modifierFlags)
            return
        }

        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.update(from: event.modifierFlags)
            return event
        }

        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.cancelPendingHintShow(resetVisible: true)
            return event
        }

        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.cancelPendingHintShow(resetVisible: true)
            }
        }

        update(from: NSEvent.modifierFlags)
    }

    func stop() {
        if let flagsMonitor {
            NSEvent.removeMonitor(flagsMonitor)
            self.flagsMonitor = nil
        }
        if let keyDownMonitor {
            NSEvent.removeMonitor(keyDownMonitor)
            self.keyDownMonitor = nil
        }
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
        cancelPendingHintShow(resetVisible: true)
    }

    private func update(from modifierFlags: NSEvent.ModifierFlags) {
        guard SidebarCommandHintPolicy.shouldShowHints(for: modifierFlags) else {
            cancelPendingHintShow(resetVisible: true)
            return
        }

        queueHintShow()
    }

    private func queueHintShow() {
        guard !isCommandPressed else { return }
        guard pendingShowWorkItem == nil else { return }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingShowWorkItem = nil
            guard SidebarCommandHintPolicy.shouldShowHints(for: NSEvent.modifierFlags) else { return }
            self.isCommandPressed = true
        }

        pendingShowWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + SidebarCommandHintPolicy.intentionalHoldDelay, execute: workItem)
    }

    private func cancelPendingHintShow(resetVisible: Bool) {
        pendingShowWorkItem?.cancel()
        pendingShowWorkItem = nil
        if resetVisible {
            isCommandPressed = false
        }
    }
}

final class TitlebarControlsAccessoryViewController: NSTitlebarAccessoryViewController, NSPopoverDelegate {
    private let hostingView: NonDraggableHostingView<TitlebarControlsView>
    private let containerView = NSView()
    private let notificationStore: TerminalNotificationStore
    private lazy var notificationsPopover: NSPopover = makeNotificationsPopover()
    private var pendingSizeUpdate = false
    private let viewModel = TitlebarControlsViewModel()
    private var userDefaultsObserver: NSObjectProtocol?
    var popoverIsShownForTesting: Bool { notificationsPopover.isShown }

    init(notificationStore: TerminalNotificationStore) {
        self.notificationStore = notificationStore
        let toggleSidebar = { _ = AppDelegate.shared?.sidebarState?.toggle() }
        let toggleNotifications: () -> Void = { _ = AppDelegate.shared?.toggleNotificationsPopover(animated: true) }
        let newTab = { _ = AppDelegate.shared?.tabManager?.addTab() }

        hostingView = NonDraggableHostingView(
            rootView: TitlebarControlsView(
                notificationStore: notificationStore,
                viewModel: viewModel,
                onToggleSidebar: toggleSidebar,
                onToggleNotifications: toggleNotifications,
                onNewTab: newTab
            )
        )

        super.init(nibName: nil, bundle: nil)

        view = containerView
        containerView.translatesAutoresizingMaskIntoConstraints = true
        hostingView.translatesAutoresizingMaskIntoConstraints = true
        hostingView.autoresizingMask = [.width, .height]
        containerView.addSubview(hostingView)

        userDefaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleSizeUpdate()
        }

        scheduleSizeUpdate()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let userDefaultsObserver {
            NotificationCenter.default.removeObserver(userDefaultsObserver)
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        scheduleSizeUpdate()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        scheduleSizeUpdate()
    }

    private func scheduleSizeUpdate() {
        guard !pendingSizeUpdate else { return }
        pendingSizeUpdate = true
        DispatchQueue.main.async { [weak self] in
            self?.pendingSizeUpdate = false
            self?.updateSize()
        }
    }

    private func updateSize() {
        hostingView.invalidateIntrinsicContentSize()
        hostingView.layoutSubtreeIfNeeded()
        let contentSize = hostingView.fittingSize
        let titlebarHeight = view.window.map { window in
            window.frame.height - window.contentLayoutRect.height
        } ?? contentSize.height
        let containerHeight = max(contentSize.height, titlebarHeight)
        let yOffset = max(0, (containerHeight - contentSize.height) / 2.0)
        preferredContentSize = NSSize(width: contentSize.width, height: containerHeight)
        containerView.frame = NSRect(x: 0, y: 0, width: contentSize.width, height: containerHeight)
        hostingView.frame = NSRect(x: 0, y: yOffset, width: contentSize.width, height: contentSize.height)
    }

    func toggleNotificationsPopover(animated: Bool = true) {
        if notificationsPopover.isShown {
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

        guard let window = view.window ?? hostingView.window ?? NSApp.keyWindow,
              let contentView = window.contentView else {
            return
        }

        // Force layout to ensure geometry is current.
        contentView.layoutSubtreeIfNeeded()

        if let anchorView = viewModel.notificationsAnchorView, anchorView.window != nil {
            anchorView.superview?.layoutSubtreeIfNeeded()
            let anchorRect = anchorView.convert(anchorView.bounds, to: contentView)
            if !anchorRect.isEmpty {
                notificationsPopover.animates = animated
                notificationsPopover.show(relativeTo: anchorRect, of: contentView, preferredEdge: .maxY)
                return
            }
        }

        // Fallback: position near top-left of the window content.
        let bounds = contentView.bounds
        let anchorRect = NSRect(x: 12, y: bounds.maxY - 8, width: 1, height: 1)
        notificationsPopover.animates = animated
        notificationsPopover.show(relativeTo: anchorRect, of: contentView, preferredEdge: .maxY)
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
    }
}

private struct NotificationsPopoverView: View {
    @ObservedObject var notificationStore: TerminalNotificationStore
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Notifications")
                    .font(.headline)
                Spacer()
                if !notificationStore.notifications.isEmpty {
                    Button("Clear All") {
                        notificationStore.clearAll()
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            if notificationStore.notifications.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "bell.slash")
                        .font(.system(size: 28))
                        .foregroundColor(.secondary)
                    Text("No notifications yet")
                        .font(.headline)
                    Text("Desktop notifications will appear here.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(minWidth: 420, idealWidth: 520, maxWidth: 640, minHeight: 180)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(notificationStore.notifications) { notification in
                            NotificationPopoverRow(
                                notification: notification,
                                tabTitle: tabTitle(for: notification.tabId),
                                onOpen: { open(notification) },
                                onClear: { notificationStore.remove(id: notification.id) }
                            )
                        }
                    }
                    .padding(12)
                }
                .frame(minWidth: 420, idealWidth: 520, maxWidth: 640, minHeight: 320, maxHeight: 480)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func tabTitle(for tabId: UUID) -> String? {
        AppDelegate.shared?.tabTitle(for: tabId)
    }

    private func open(_ notification: TerminalNotification) {
        // SwiftUI action closures are not guaranteed to run on the main actor.
        // Ensure window focus + tab selection happens on the main thread.
        DispatchQueue.main.async {
            _ = AppDelegate.shared?.openNotification(
                tabId: notification.tabId,
                surfaceId: notification.surfaceId,
                notificationId: notification.id
            )
            onDismiss()
        }
    }
}

private struct NotificationPopoverRow: View {
    let notification: TerminalNotification
    let tabTitle: String?
    let onOpen: () -> Void
    let onClear: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: onOpen) {
                HStack(alignment: .top, spacing: 10) {
                    Circle()
                        .fill(notification.isRead ? Color.clear : Color.accentColor)
                        .frame(width: 8, height: 8)
                        .overlay(
                            Circle()
                                .stroke(Color.accentColor.opacity(notification.isRead ? 0.2 : 1), lineWidth: 1)
                        )
                        .padding(.top, 6)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(notification.title)
                                .font(.headline)
                                .foregroundColor(.primary)
                            Spacer()
                            Text(notification.createdAt.formatted(date: .omitted, time: .shortened))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        if !notification.body.isEmpty {
                            Text(notification.body)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .lineLimit(3)
                        }

                        if let tabTitle {
                            Text(tabTitle)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    Spacer(minLength: 0)
                }
                .padding(.trailing, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("NotificationPopoverRow.\(notification.id.uuidString)")
            // XCUITest's `.click()` is not always reliable for SwiftUI `Button`s hosted in an `NSPopover`.
            // Provide an explicit accessibility action so AXPress always routes to `onOpen`.
            .accessibilityAction { onOpen() }

            Button(action: onClear) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}

final class UpdateTitlebarAccessoryController {
    private weak var updateViewModel: UpdateViewModel?
    private var didStart = false
    private let attachedWindows = NSHashTable<NSWindow>.weakObjects()
    private var observers: [NSObjectProtocol] = []
    private var pendingAttachRetries: [ObjectIdentifier: Int] = [:]
    private var startupScanWorkItems: [DispatchWorkItem] = []
    private let controlsIdentifier = NSUserInterfaceItemIdentifier("cmux.titlebarControls")
    private let controlsControllers = NSHashTable<TitlebarControlsAccessoryViewController>.weakObjects()

    init(viewModel: UpdateViewModel) {
        self.updateViewModel = viewModel
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        attachToExistingWindows()
        installObservers()
        scheduleStartupWindowScans()
    }

    func attach(to window: NSWindow) {
        attachIfNeeded(to: window)
    }

    private func installObservers() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSWindow.didBecomeMainNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow else { return }
            self?.attachIfNeeded(to: window)
        })

        observers.append(center.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow else { return }
            self?.attachIfNeeded(to: window)
        })

        // We intentionally do not rely on "window became visible" notifications here:
        // AppKit does not provide a stable cross-SDK API for this. Startup scans handle this case.
    }

    private func attachToExistingWindows() {
        for window in NSApp.windows {
            attachIfNeeded(to: window)
        }
    }

    private func scheduleStartupWindowScans() {
        // We want to be robust to SwiftUI/AppKit timing and to XCTest automation. Scanning
        // NSApp.windows briefly at startup is cheap and ensures accessories are attached even
        // if key/main/visible notifications are missed.
        let delays: [TimeInterval] = [0.05, 0.15, 0.3, 0.6, 1.0, 2.0, 3.0]
        for delay in delays {
            let item = DispatchWorkItem { [weak self] in
                self?.attachToExistingWindows()
#if DEBUG
                let env = ProcessInfo.processInfo.environment
                if env["CMUX_UI_TEST_MODE"] == "1" {
                    let ids = NSApp.windows.map { $0.identifier?.rawValue ?? "<nil>" }
                    let delayText = String(format: "%.2f", delay)
                    UpdateLogStore.shared.append("startup window scan (delay=\(delayText)) count=\(NSApp.windows.count) ids=\(ids.joined(separator: ","))")
                }
#endif
            }
            startupScanWorkItems.append(item)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        }
    }

    private func attachIfNeeded(to window: NSWindow) {
        guard !attachedWindows.contains(window) else { return }
        guard !isSettingsWindow(window) else { return }

        // Window identifiers are assigned by SwiftUI via WindowAccessor, which can run
        // after didBecomeKey/didBecomeMain notifications. Retry briefly to avoid missing
        // attaching accessories (notably in UI tests).
        if !isMainTerminalWindow(window) {
            let key = ObjectIdentifier(window)
            let attempts = pendingAttachRetries[key, default: 0]
            if attempts < 40 {
                pendingAttachRetries[key] = attempts + 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak window] in
                    guard let self, let window else { return }
                    self.attachIfNeeded(to: window)
                }
            } else {
                pendingAttachRetries.removeValue(forKey: key)
            }
            return
        }

        pendingAttachRetries.removeValue(forKey: ObjectIdentifier(window))

        if !window.titlebarAccessoryViewControllers.contains(where: { $0.view.identifier == controlsIdentifier }) {
            let controls = TitlebarControlsAccessoryViewController(
                notificationStore: TerminalNotificationStore.shared
            )
            controls.layoutAttribute = .left
            controls.view.identifier = controlsIdentifier
            window.addTitlebarAccessoryViewController(controls)
            controlsControllers.add(controls)
        }

        attachedWindows.add(window)

#if DEBUG
        let env = ProcessInfo.processInfo.environment
        if env["CMUX_UI_TEST_MODE"] == "1" {
            let ident = window.identifier?.rawValue ?? "<nil>"
            UpdateLogStore.shared.append("attached titlebar accessories to window id=\(ident)")
        }
#endif
    }

    private func isSettingsWindow(_ window: NSWindow) -> Bool {
        if window.identifier?.rawValue == "cmux.settings" {
            return true
        }
        return window.title == "Settings"
    }

    private func isMainTerminalWindow(_ window: NSWindow) -> Bool {
        guard let raw = window.identifier?.rawValue else { return false }
        return raw == "cmux.main" || raw.hasPrefix("cmux.main.")
    }

    private func preferredNotificationsController(
        from controllers: [TitlebarControlsAccessoryViewController],
        preferShownPopover: Bool
    ) -> TitlebarControlsAccessoryViewController? {
        if let keyWindow = NSApp.keyWindow,
           let match = controllers.first(where: { $0.view.window === keyWindow }) {
            return match
        }
        if let keyMain = NSApp.windows.first(where: { $0.isKeyWindow && isMainTerminalWindow($0) }),
           let match = controllers.first(where: { $0.view.window === keyMain }) {
            return match
        }
        if preferShownPopover,
           let shown = controllers.first(where: { $0.popoverIsShownForTesting }) {
            return shown
        }
        return controllers.first
    }

    func toggleNotificationsPopover(animated: Bool = true) {
        let controllers = controlsControllers.allObjects
        guard !controllers.isEmpty else { return }

        let target = preferredNotificationsController(from: controllers, preferShownPopover: true)
        for controller in controllers {
            if controller !== target {
                controller.dismissNotificationsPopover()
            }
        }
        target?.toggleNotificationsPopover(animated: animated)
    }

    func isNotificationsPopoverShown() -> Bool {
        controlsControllers.allObjects.contains(where: { $0.popoverIsShownForTesting })
    }

    @discardableResult
    func dismissNotificationsPopoverIfShown() -> Bool {
        let controllers = controlsControllers.allObjects
        var dismissed = false
        for controller in controllers where controller.popoverIsShownForTesting {
            controller.dismissNotificationsPopover()
            dismissed = true
        }
        return dismissed
    }

    func showNotificationsPopover(animated: Bool = true) {
        let controllers = controlsControllers.allObjects
        guard !controllers.isEmpty else { return }

        let target = preferredNotificationsController(from: controllers, preferShownPopover: false)
        for controller in controllers {
            if controller !== target {
                controller.dismissNotificationsPopover()
            }
        }
        guard let target else { return }
        if target.popoverIsShownForTesting {
            return
        }
        target.toggleNotificationsPopover(animated: animated)
    }
}
