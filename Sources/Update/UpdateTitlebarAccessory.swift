import AppKit
import Combine
import SwiftUI

final class NonDraggableHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { false }
}

#if DEBUG
private struct DevTitlebarAccessoryView: View {
    var body: some View {
        Text("THIS IS A DEV BUILD")
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.red)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
    }
}

final class DevBuildAccessoryViewController: NSTitlebarAccessoryViewController {
    private let hostingView: NonDraggableHostingView<DevTitlebarAccessoryView>
    private let containerView = NSView()
    private var pendingSizeUpdate = false

    init() {
        hostingView = NonDraggableHostingView(rootView: DevTitlebarAccessoryView())

        super.init(nibName: nil, bundle: nil)

        view = containerView
        containerView.translatesAutoresizingMaskIntoConstraints = true
        hostingView.translatesAutoresizingMaskIntoConstraints = true
        hostingView.autoresizingMask = [.width, .height]
        containerView.addSubview(hostingView)

        scheduleSizeUpdate()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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
        let labelSize = hostingView.fittingSize
        let titlebarHeight = view.window.map { window in
            window.frame.height - window.contentLayoutRect.height
        } ?? labelSize.height
        let containerHeight = max(labelSize.height, titlebarHeight)
        let yOffset = max(0, (containerHeight - labelSize.height) / 2.0)
        preferredContentSize = NSSize(width: labelSize.width, height: containerHeight)
        containerView.frame = NSRect(x: 0, y: 0, width: labelSize.width, height: containerHeight)
        hostingView.frame = NSRect(x: 0, y: yOffset, width: labelSize.width, height: labelSize.height)
    }
}
#endif

private struct TitlebarAccessoryView: View {
    @ObservedObject var model: UpdateViewModel

    var body: some View {
        UpdatePill(model: model)
        .padding(.trailing, 8)
    }
}

private struct TitlebarControlsView: View {
    @ObservedObject var notificationStore: TerminalNotificationStore
    let onToggleSidebar: () -> Void
    let onNewTab: () -> Void
    @State private var isShowingNotifications = false

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onToggleSidebar) {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Toggle Sidebar")

            Button(action: { isShowingNotifications.toggle() }) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "bell")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 24, height: 24)

                    if notificationStore.unreadCount > 0 {
                        Text("\(min(notificationStore.unreadCount, 99))")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 14, height: 14)
                            .background(
                                Circle().fill(Color.accentColor)
                            )
                            .offset(x: 2, y: -2)
                    }
                }
                .frame(width: 26, height: 24)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Notifications")
            .popover(isPresented: $isShowingNotifications, arrowEdge: .top) {
                NotificationsPopoverView(notificationStore: notificationStore)
            }

            Button(action: onNewTab) {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("New Tab")
        }
        .padding(.leading, 4)
    }
}

final class TitlebarControlsAccessoryViewController: NSTitlebarAccessoryViewController {
    private let hostingView: NonDraggableHostingView<TitlebarControlsView>
    private let containerView = NSView()
    private var pendingSizeUpdate = false

    init(notificationStore: TerminalNotificationStore) {
        let toggleSidebar = { _ = AppDelegate.shared?.sidebarState?.toggle() }
        let newTab = { _ = AppDelegate.shared?.tabManager?.addTab() }

        hostingView = NonDraggableHostingView(
            rootView: TitlebarControlsView(
                notificationStore: notificationStore,
                onToggleSidebar: toggleSidebar,
                onNewTab: newTab
            )
        )

        super.init(nibName: nil, bundle: nil)

        view = containerView
        containerView.translatesAutoresizingMaskIntoConstraints = true
        hostingView.translatesAutoresizingMaskIntoConstraints = true
        hostingView.autoresizingMask = [.width, .height]
        containerView.addSubview(hostingView)

        scheduleSizeUpdate()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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
}

private struct NotificationsPopoverView: View {
    @ObservedObject var notificationStore: TerminalNotificationStore

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
                .frame(width: 320, height: 180)
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
                .frame(width: 360, height: 360)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func tabTitle(for tabId: UUID) -> String? {
        AppDelegate.shared?.tabManager?.tabs.first(where: { $0.id == tabId })?.title
    }

    private func open(_ notification: TerminalNotification) {
        AppDelegate.shared?.tabManager?.focusTabFromNotification(notification.tabId, surfaceId: notification.surfaceId)
        markReadIfFocused(notification)
    }

    private func markReadIfFocused(_ notification: TerminalNotification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard let tabManager = AppDelegate.shared?.tabManager else { return }
            guard tabManager.selectedTabId == notification.tabId else { return }
            if let surfaceId = notification.surfaceId {
                guard tabManager.focusedSurfaceId(for: notification.tabId) == surfaceId else { return }
            }
            notificationStore.markRead(id: notification.id)
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
                    Text(notification.createdAt, style: .time)
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
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
    }
}

final class UpdateAccessoryViewController: NSTitlebarAccessoryViewController {
    private let hostingView: NonDraggableHostingView<TitlebarAccessoryView>
    private let containerView = NSView()
    private var stateCancellable: AnyCancellable?
    private var pendingSizeUpdate = false

    init(model: UpdateViewModel) {
        hostingView = NonDraggableHostingView(rootView: TitlebarAccessoryView(model: model))

        super.init(nibName: nil, bundle: nil)

        view = containerView
        containerView.translatesAutoresizingMaskIntoConstraints = true
        hostingView.translatesAutoresizingMaskIntoConstraints = true
        hostingView.autoresizingMask = [.width, .height]
        containerView.addSubview(hostingView)

        stateCancellable = model.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.scheduleSizeUpdate()
            }

        scheduleSizeUpdate()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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
        let pillSize = hostingView.fittingSize
        let titlebarHeight = view.window.map { window in
            window.frame.height - window.contentLayoutRect.height
        } ?? pillSize.height
        let containerHeight = max(pillSize.height, titlebarHeight)
        let yOffset = max(0, (containerHeight - pillSize.height) / 2.0)
        preferredContentSize = NSSize(width: pillSize.width, height: containerHeight)
        containerView.frame = NSRect(x: 0, y: 0, width: pillSize.width, height: containerHeight)
        hostingView.frame = NSRect(x: 0, y: yOffset, width: pillSize.width, height: pillSize.height)
    }
}

final class UpdateTitlebarAccessoryController {
    private weak var updateViewModel: UpdateViewModel?
    private var didStart = false
    private let attachedWindows = NSHashTable<NSWindow>.weakObjects()
    private var observers: [NSObjectProtocol] = []
    private var stateCancellable: AnyCancellable?
    private var lastIsIdle: Bool?
    private let updateIdentifier = NSUserInterfaceItemIdentifier("cmux.updateAccessory")
    private let controlsIdentifier = NSUserInterfaceItemIdentifier("cmux.titlebarControls")
#if DEBUG
    private let devIdentifier = NSUserInterfaceItemIdentifier("cmux.devAccessory")
#endif

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
        installStateObserver()
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
    }

    private func attachToExistingWindows() {
        for window in NSApp.windows {
            attachIfNeeded(to: window)
        }
    }

    private func attachIfNeeded(to window: NSWindow) {
        guard let updateViewModel else { return }
        guard !attachedWindows.contains(window) else { return }
        guard window.styleMask.contains(.titled) else { return }
        guard !isSettingsWindow(window) else { return }

        if !window.titlebarAccessoryViewControllers.contains(where: { $0.view.identifier == controlsIdentifier }) {
            let controls = TitlebarControlsAccessoryViewController(
                notificationStore: TerminalNotificationStore.shared
            )
            controls.layoutAttribute = .left
            controls.view.identifier = controlsIdentifier
            window.addTitlebarAccessoryViewController(controls)
        }

#if DEBUG
        if !window.titlebarAccessoryViewControllers.contains(where: { $0.view.identifier == devIdentifier }) {
            let devAccessory = DevBuildAccessoryViewController()
            devAccessory.layoutAttribute = .left
            devAccessory.view.identifier = devIdentifier
            window.addTitlebarAccessoryViewController(devAccessory)
        }
#endif

        if !window.titlebarAccessoryViewControllers.contains(where: { $0.view.identifier == updateIdentifier }) {
            let accessory = UpdateAccessoryViewController(model: updateViewModel)
            accessory.layoutAttribute = .right
            accessory.view.identifier = updateIdentifier
            window.addTitlebarAccessoryViewController(accessory)
        }

        attachedWindows.add(window)
    }

    private func isSettingsWindow(_ window: NSWindow) -> Bool {
        if window.identifier?.rawValue == "cmux.settings" {
            return true
        }
        return window.title == "Settings"
    }

    private func installStateObserver() {
        guard let updateViewModel else { return }
        stateCancellable = Publishers.CombineLatest(updateViewModel.$state, updateViewModel.$overrideState)
            .map { state, override in
                override ?? state
            }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                let isIdle = state.isIdle
                if let lastIsIdle, lastIsIdle == isIdle {
                    return
                }
                self.lastIsIdle = isIdle
                self.refreshAccessories(isIdle: isIdle)
            }
    }

    private func refreshAccessories(isIdle: Bool) {
        guard let updateViewModel else { return }

        for window in attachedWindows.allObjects {
            if let index = window.titlebarAccessoryViewControllers.firstIndex(where: { $0.view.identifier == updateIdentifier }) {
                window.removeTitlebarAccessoryViewController(at: index)
            }

            guard !isIdle else { continue }

            let accessory = UpdateAccessoryViewController(model: updateViewModel)
            accessory.layoutAttribute = .right
            accessory.view.identifier = updateIdentifier
            window.addTitlebarAccessoryViewController(accessory)
        }
    }
}
