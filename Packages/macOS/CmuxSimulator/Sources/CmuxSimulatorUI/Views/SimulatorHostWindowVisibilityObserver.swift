import AppKit
import SwiftUI

struct SimulatorHostWindowVisibilityObserver: NSViewRepresentable {
    let onVisibilityChanged: @MainActor (UUID, Bool) -> Void
    let onRemoval: @MainActor (UUID) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> SimulatorHostWindowVisibilityView {
        let view = SimulatorHostWindowVisibilityView()
        installHandlers(on: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ view: SimulatorHostWindowVisibilityView, context: Context) {
        installHandlers(on: view, coordinator: context.coordinator)
    }

    static func dismantleNSView(
        _ view: SimulatorHostWindowVisibilityView,
        coordinator: Coordinator
    ) {
        view.teardown()
        coordinator.remove()
    }

    private func installHandlers(
        on view: SimulatorHostWindowVisibilityView,
        coordinator: Coordinator
    ) {
        let observerID = coordinator.observerID
        coordinator.onRemoval = onRemoval
        view.setVisibilityHandler { isVisible in
            onVisibilityChanged(observerID, isVisible)
        }
    }

    @MainActor
    final class Coordinator {
        let observerID = UUID()
        var onRemoval: ((UUID) -> Void)?
        private var wasRemoved = false

        func remove() {
            guard !wasRemoved else { return }
            wasRemoved = true
            onRemoval?(observerID)
            onRemoval = nil
        }
    }
}

@MainActor
final class SimulatorHostWindowVisibilityView: NSView {
    private var onVisibilityChanged: ((Bool) -> Void)?
    private var lastVisibility: Bool?
    private var isTornDown = false

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if window !== newWindow {
            NotificationCenter.default.removeObserver(self)
            publishVisibility(false)
        }
        super.viewWillMove(toWindow: newWindow)
        guard let newWindow else { return }
        for name in [
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
        ] {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowVisibilityDidChange(_:)),
                name: name,
                object: newWindow
            )
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reconcileVisibility()
    }

    func setVisibilityHandler(_ handler: @escaping (Bool) -> Void) {
        onVisibilityChanged = handler
        publishVisibility(
            window.map(simulatorHostWindowIsVisible) ?? false,
            force: true
        )
    }

    func reconcileVisibility() {
        guard !isTornDown else { return }
        publishVisibility(window.map(simulatorHostWindowIsVisible) ?? false)
    }

    func teardown() {
        guard !isTornDown else { return }
        isTornDown = true
        NotificationCenter.default.removeObserver(self)
        publishVisibility(false)
        onVisibilityChanged = nil
    }

    private func publishVisibility(_ isVisible: Bool, force: Bool = false) {
        guard force || lastVisibility != isVisible else { return }
        lastVisibility = isVisible
        onVisibilityChanged?(isVisible)
    }

    @objc private func windowVisibilityDidChange(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        reconcileVisibility()
    }
}

@MainActor
func simulatorHostWindowIsVisible(_ window: NSWindow) -> Bool {
    window.isVisible
        && !window.isMiniaturized
        && window.occlusionState.contains(.visible)
}
