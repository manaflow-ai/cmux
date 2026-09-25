import AppKit
import SwiftUI

/// Shows one Network sheet at a time on the main window, like
/// ``NewMachineSheetPresenter``. The sheet reads and writes through
/// ``VMClient``, the same calls `cmux vm network` reaches through the socket.
@MainActor
final class CloudNetworkPolicySheetPresenter {
    static let shared = CloudNetworkPolicySheetPresenter()

    private var sheetWindow: NSWindow?
    private var hostWindow: NSWindow?
    private var model: CloudNetworkPolicySheetModel?
    private var loadTask: Task<Void, Never>?

    private init() {}

    func present(machineID: String, machineLabel: String?, preferredWindow: NSWindow?) {
        if sheetWindow != nil {
            (hostWindow ?? sheetWindow)?.makeKeyAndOrderFront(nil)
            return
        }
        let model = CloudNetworkPolicySheetModel(
            machineID: machineID,
            machineLabel: machineLabel,
            load: { id in
                guard let client = VMClient.shared else { throw VMClientError.notSignedIn }
                return try await client.networkPolicy(id: id)
            },
            save: { id, policy in
                guard let client = VMClient.shared else { throw VMClientError.notSignedIn }
                return try await client.setNetworkPolicy(id: id, policy: policy)
            }
        )
        model.onFinished = { [weak self] _ in self?.dismiss() }
        let controller = NSHostingController(rootView: CloudNetworkPolicySheet(model: model))
        controller.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled]
        window.title = String(localized: "cloud.network.section.label", defaultValue: "Network")
        window.isReleasedWhenClosed = false
        self.model = model
        sheetWindow = window
        loadTask = Task { [weak model] in await model?.load() }

        let host = NSApp.cmuxMainWindowForModalPresentation(preferring: preferredWindow)
        if let host, host.attachedSheet == nil {
            hostWindow = host
            host.beginSheet(window) { _ in }
        } else {
            hostWindow = nil
            window.center()
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func dismiss() {
        loadTask?.cancel()
        loadTask = nil
        guard let window = sheetWindow else { return }
        if let host = hostWindow, host.attachedSheet === window {
            host.endSheet(window)
        }
        window.orderOut(nil)
        sheetWindow = nil
        hostWindow = nil
        model = nil
    }
}
