import AppKit
import CmuxCloud
import SwiftUI

/// Shows one Cloud Secrets sheet at a time on the main window, like
/// ``CloudNetworkPolicySheetPresenter``. Every read and write goes through
/// ``CloudSecretsService``, the same owner `cmux vm secrets` reaches through
/// the socket, so the sheet and the CLI cannot disagree.
@MainActor
final class CloudSecretsSheetPresenter {
    static let shared = CloudSecretsSheetPresenter()

    private var sheetWindow: NSWindow?
    private var sheetController: CloudSheetWindow?
    private var hostWindow: NSWindow?
    private var model: CloudSecretsSheetModel?
    private var presentedMachineID: String?
    private var loadTask: Task<Void, Never>?
    private var changeObserver: NSObjectProtocol?

    private init() {}

    /// Opens the sheet. With a machine it is that machine's view: per-name
    /// delivery state and Sync Now. Opening for a different machine replaces
    /// the open sheet; the same one is brought forward.
    func present(machineID: String? = nil, machineLabel: String? = nil, preferredWindow: NSWindow?) {
        if sheetWindow != nil {
            if presentedMachineID == machineID {
                (hostWindow ?? sheetWindow)?.makeKeyAndOrderFront(nil)
                return
            }
            dismiss()
        }
        let service = CloudSecretsService.shared
        let model = CloudSecretsSheetModel(
            machineID: machineID,
            machineLabel: machineLabel,
            backend: Self.backend(service)
        )
        model.onFinished = { [weak self] in self?.dismiss() }
        let sheet = CloudSheetWindow(rootView: CloudSecretsSheet(model: model))
        let window = sheet.window
        window.styleMask = [.titled]
        window.title = String(localized: "cloudSecrets.sheet.title", defaultValue: "Cloud Secrets")
        window.isReleasedWhenClosed = false
        self.model = model
        presentedMachineID = machineID
        sheetController = sheet
        sheetWindow = window
        loadTask = Task { [weak model] in await model?.load() }
        // Syncs started by a save (or by the CLI) finish after the sheet's own
        // write; reread so row states and "Delivered …" stay true.
        changeObserver = NotificationCenter.default.addObserver(
            forName: CloudSecretsService.didChangeNotification, object: nil, queue: .main
        ) { [weak model] _ in
            MainActor.assumeIsolated {
                guard let model else { return }
                Task { await model.load() }
            }
        }

        let host = NSApp.cmuxMainWindowForModalPresentation(preferring: preferredWindow)
        if let host, host.attachedSheet == nil {
            hostWindow = host
            sheet.beginSheet(on: host)
        } else {
            hostWindow = nil
            sheet.orderFrontFloating()
        }
    }

    /// Lets the Cloud "Get started" card open this sheet.
    func installGettingStartedBridge(_ bridge: CloudGettingStartedSecretsBridge) {
        bridge.openSecrets = { [weak self] in
            self?.present(preferredWindow: NSApp.keyWindow ?? NSApp.mainWindow)
        }
    }

    /// Binds the sheet to the service. Saves return as soon as the vault is
    /// written; delivery to affected machines continues in the background
    /// when auto-sync is on, and the change notification refreshes the sheet.
    static func backend(_ service: CloudSecretsService) -> CloudSecretsSheetBackend {
        CloudSecretsSheetBackend(
            load: {
                await service.reload()
                if let error = service.loadError, service.records.isEmpty {
                    throw CloudSecretsSheetLoadError(message: error)
                }
                return CloudSecretsSheetBackend.Snapshot(records: service.records, deliveries: service.deliveries)
            },
            set: { inputs, scope, source in
                let result = try await service.set(inputs, scope: scope, source: source, sync: false)
                syncInBackground(service)
                return result.changes
            },
            remove: { names, scope in
                let result = try await service.remove(names: names, scope: scope, sync: false)
                syncInBackground(service)
                return result.changes
            },
            preview: { inputs, scope in
                try await service.preview(inputs, scope: scope)
            },
            status: { machineID in
                try await service.status(machineID: machineID, verify: false)
            },
            sync: { machineID in
                await service.sync(machineID: machineID).error
            }
        )
    }

    private static func syncInBackground(_ service: CloudSecretsService) {
        guard service.isAutoSyncEnabled else { return }
        Task { @MainActor in
            await service.syncAllStale()
        }
    }

    private func dismiss() {
        loadTask?.cancel()
        loadTask = nil
        if let changeObserver {
            NotificationCenter.default.removeObserver(changeObserver)
        }
        changeObserver = nil
        guard let window = sheetWindow else { return }
        if let host = hostWindow, host.attachedSheet === window {
            host.endSheet(window)
        }
        window.orderOut(nil)
        sheetController = nil
        sheetWindow = nil
        hostWindow = nil
        model = nil
        presentedMachineID = nil
    }
}

/// The vault could not be read; the text is already redacted.
struct CloudSecretsSheetLoadError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
