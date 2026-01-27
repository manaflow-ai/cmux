import AppKit
import Combine
import SwiftUI

final class NonDraggableHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { false }
}

private struct TitlebarAccessoryView: View {
    @ObservedObject var model: UpdateViewModel
    let onIdleTap: () -> Void

    var body: some View {
        UpdatePill(
            model: model,
            showWhenIdle: false,
            onIdleTap: onIdleTap
        )
        .fixedSize()
        .padding(.top, 4)
        .padding(.trailing, 8)
    }
}

final class UpdateAccessoryViewController: NSTitlebarAccessoryViewController {
    private var sizeCancellable: AnyCancellable?

    init(model: UpdateViewModel, onIdleTap: @escaping () -> Void) {
        super.init(nibName: nil, bundle: nil)

        let hostingView = NonDraggableHostingView(rootView: TitlebarAccessoryView(
            model: model,
            onIdleTap: onIdleTap
        ))
        hostingView.setFrameSize(hostingView.fittingSize)
        view = hostingView

        sizeCancellable = model.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak hostingView] _ in
                guard let hostingView else { return }
                hostingView.invalidateIntrinsicContentSize()
                hostingView.layoutSubtreeIfNeeded()
                hostingView.setFrameSize(hostingView.fittingSize)
            }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class UpdateTitlebarAccessoryController {
    private weak var updateViewModel: UpdateViewModel?
    private var didStart = false
    private let attachedWindows = NSHashTable<NSWindow>.weakObjects()
    private var observers: [NSObjectProtocol] = []

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

        let identifier = NSUserInterfaceItemIdentifier("cmux.updateAccessory")
        if window.titlebarAccessoryViewControllers.contains(where: { $0.view.identifier == identifier }) {
            attachedWindows.add(window)
            return
        }

        let accessory = UpdateAccessoryViewController(
            model: updateViewModel,
            onIdleTap: {
                guard let delegate = NSApp.delegate as? AppDelegate else { return }
                delegate.checkForUpdates(nil)
            }
        )
        accessory.layoutAttribute = .right

        accessory.view.identifier = identifier

        window.addTitlebarAccessoryViewController(accessory)
        attachedWindows.add(window)
    }
}
