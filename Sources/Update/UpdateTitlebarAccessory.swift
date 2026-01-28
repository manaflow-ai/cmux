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
