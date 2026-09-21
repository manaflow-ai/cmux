import AppKit
import SwiftUI

/// Owns one reusable setup window and observes VPN state only while it is open.
@MainActor
final class CloudVPNSetupWindowController: ReleasingWindowController {
    let model: CloudVPNSetupModel
    private var observation: Task<Void, Never>?

    init(coordinator: CloudTunnelCoordinator?) {
        model = CloudVPNSetupModel(coordinator: coordinator)
        super.init()
    }

    deinit { observation?.cancel() }

    func attachIfNeeded(_ coordinator: CloudTunnelCoordinator) {
        guard model.attachIfNeeded(coordinator), window != nil else { return }
        observeWhileOpen()
    }

    override func makeWindow() -> NSWindow {
        model.prepareForPresentation()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 480),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = String(localized: "cloud.vpn.setup.title", defaultValue: "Cloud VPN")
        window.identifier = NSUserInterfaceItemIdentifier("cmux.cloudVPNSetup")
        window.contentMinSize = NSSize(width: 400, height: 260)
        window.contentView = NSHostingView(rootView: CloudVPNSetupView(
            model: model,
            openSystemSettings: SystemExtensionSettingsLink.open
        ))
        observeWhileOpen()
        return window
    }

    override func managedWindowWillClose(_ window: NSWindow) {
        observation?.cancel()
        observation = nil
        // An explicitly enabled VPN belongs to the coordinator, not this window.
    }

    private func observeWhileOpen() {
        observation?.cancel()
        observation = Task { [model] in
            await model.refresh()
            await model.observe()
        }
    }
}
