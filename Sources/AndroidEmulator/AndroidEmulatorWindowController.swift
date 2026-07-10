import AppKit
import CmuxAndroidEmulator
import CmuxAndroidEmulatorUI
import SwiftUI

/// App-owned window that hosts the user-installed Android emulator picker.
@MainActor
final class AndroidEmulatorWindowController: ReleasingWindowController {
    private let coordinator: AndroidEmulatorCoordinator
    private let onOpenInPane: (AndroidVirtualDevice) -> Void

    init(
        coordinator: AndroidEmulatorCoordinator,
        onOpenInPane: @escaping (AndroidVirtualDevice) -> Void
    ) {
        self.coordinator = coordinator
        self.onOpenInPane = onOpenInPane
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("cmux.androidEmulators")
        window.title = String(
            localized: "androidEmulator.window.title",
            defaultValue: "Android Emulators"
        )
        window.minSize = NSSize(width: 520, height: 360)
        window.contentView = NSHostingView(rootView: AndroidEmulatorPickerView(
            coordinator: coordinator,
            onOpenInPane: onOpenInPane
        ))
        AppDelegate.shared?.applyWindowDecorations(to: window)
        return window
    }

    func show() {
        NSApp.unhide(nil)
        showManagedWindow(activateApplication: true)
        Task { await coordinator.refresh() }
    }
}

extension AppDelegate {
    /// Opens the Android emulator picker through the shared composition-root instance.
    func showAndroidEmulators() {
        androidEmulatorEnvironment.windowController.show()
    }

    func openAndroidEmulatorPane(_ device: AndroidVirtualDevice) {
        guard let workspace = tabManager?.selectedWorkspace else { return }
        _ = workspace.openAndroidEmulatorPane(
            device: device,
            coordinator: androidEmulatorEnvironment.coordinator
        )
    }

    func openFirstRunningAndroidEmulatorPane() -> Bool {
        guard case .loaded(let snapshot) = androidEmulatorEnvironment.coordinator.loadState,
              let device = snapshot.devices.first(where: { $0.state.isRunning }) else {
            return false
        }
        openAndroidEmulatorPane(device)
        return true
    }
}
