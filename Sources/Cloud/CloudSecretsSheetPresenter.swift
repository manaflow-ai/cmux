import AppKit
import CmuxCloud
import Combine
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
    private var syncingSubscription: AnyCancellable?
    private var onDismiss: (() -> Void)?

    private init() {}

#if DEBUG
    /// The open sheet for the `debug.cloud_secrets.*` socket verbs.
    var debugOpenSheet: (model: CloudSecretsSheetModel, window: NSWindow, host: NSWindow?)? {
        guard let model, let sheetWindow else { return nil }
        return (model, sheetWindow, hostWindow)
    }
#endif

    /// Opens the sheet. With a machine it is that machine's view: per-name
    /// delivery state and Sync Now. Opening for a different machine replaces
    /// the open sheet; the same one is brought forward.
    func present(
        machineID: String? = nil,
        machineLabel: String? = nil,
        preferredWindow: NSWindow?,
        onDismiss: (() -> Void)? = nil
    ) {
        if sheetWindow != nil {
            if presentedMachineID == machineID {
                self.onDismiss = self.onDismiss ?? onDismiss
                (hostWindow ?? sheetWindow)?.makeKeyAndOrderFront(nil)
                return
            }
            // A replacement sheet keeps the caller waiting on the first one.
            let pendingDismiss = self.onDismiss
            self.onDismiss = nil
            dismiss()
            self.onDismiss = pendingDismiss
        }
        let service = CloudSecretsService.shared
        let cloudContext = machineID == nil ? Self.contextCloudWorkspace(preferredWindow: preferredWindow) : nil
        let model = CloudSecretsSheetModel(
            machineID: machineID,
            machineLabel: machineLabel,
            contextCheckout: machineID == nil ? Self.contextCheckout(preferredWindow: preferredWindow) : nil,
            contextMachineID: cloudContext?.machineID,
            contextDirectoryName: cloudContext?.directoryName,
            backend: Self.backend(service)
        )
        model.onFinished = { [weak self] in self?.dismiss() }
        let sheet = CloudSheetWindow(rootView: CloudSecretsSheet(model: model))
        let window = sheet.window
        window.styleMask = [.titled]
        // An opaque sheet with its shadow, so it reads as a surface above the
        // dimmed window instead of letting the panel behind show through.
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
        window.hasShadow = true
        window.title = String(localized: "cloudSecrets.sheet.title", defaultValue: "Cloud Secrets")
        window.isReleasedWhenClosed = false
        self.model = model
        self.onDismiss = onDismiss ?? self.onDismiss
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
        // A delivery someone else started (machine creation, the CLI) shows as
        // "Syncing…" on this machine's sheet, not as missing values.
        if let machineID {
            syncingSubscription = service.$syncingMachineIDs
                .map { $0.contains(machineID) }
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .sink { [weak model] inFlight in
                    MainActor.assumeIsolated { model?.setExternalSyncInFlight(inFlight) }
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

    /// The git checkout the window's selected local workspace is in, so the
    /// Project tab can list the names that repository declares. nil for a Cloud
    /// workspace or a folder outside any checkout.
    private static func contextCheckout(preferredWindow: NSWindow?) -> CloudSecretProjectCheckout? {
        guard let workspace = AppDelegate.shared?.activeTabManagerForCommands(preferredWindow: preferredWindow)?.selectedWorkspace,
              workspace.cloudVMID == nil else { return nil }
        let directory = workspace.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard directory.hasPrefix("/") else { return nil }
        return CloudSecretProjectCheckout.locate(from: URL(fileURLWithPath: directory, isDirectory: true))
    }

    /// The machine and folder of the window's selected Cloud workspace, so the
    /// Project tab can start on the project that machine is linked to and list
    /// what it still needs. nil for a local workspace.
    private static func contextCloudWorkspace(preferredWindow: NSWindow?) -> (machineID: String, directoryName: String?)? {
        guard let workspace = AppDelegate.shared?.activeTabManagerForCommands(preferredWindow: preferredWindow)?.selectedWorkspace,
              let machineID = workspace.cloudVMID, !machineID.isEmpty else { return nil }
        let directory = workspace.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = directory.isEmpty ? nil : URL(fileURLWithPath: directory).lastPathComponent
        return (machineID, name)
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
                try await service.set(inputs, scope: scope, source: source, sync: false).changes
            },
            remove: { names, scope in
                try await service.remove(names: names, scope: scope, sync: false).changes
            },
            preview: { inputs, scope in
                try await service.preview(inputs, scope: scope)
            },
            status: { machineID in
                try await service.status(machineID: machineID, verify: false)
            },
            sync: { machineID in
                await service.sync(machineID: machineID).error
            },
            declared: { root in
                // Names only; the files are small, but read them off the main actor.
                await Task.detached(priority: .userInitiated) {
                    CloudSecretRequirements.declared(inDirectory: root)
                }.value
            },
            declaredForProject: { projectKey in
                service.declaredRequirementsByProject[projectKey] ?? []
            },
            // Saves return once the vault is written; the sheet then runs this in
            // the background when auto-sync is on.
            autoSync: {
                guard service.isAutoSyncEnabled else { return nil }
                return { _ = await service.syncAllStale() }
            }
        )
    }

    private func dismiss() {
        loadTask?.cancel()
        loadTask = nil
        if let changeObserver {
            NotificationCenter.default.removeObserver(changeObserver)
        }
        changeObserver = nil
        syncingSubscription = nil
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
        let onDismiss = self.onDismiss
        self.onDismiss = nil
        onDismiss?()
    }
}

/// The vault could not be read; the text is already redacted.
struct CloudSecretsSheetLoadError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
