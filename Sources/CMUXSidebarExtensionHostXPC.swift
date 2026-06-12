@_spi(CmuxHostTransport) import CMUXExtensionHostSupport
@_spi(CmuxHostTransport) import CmuxExtensionKit
import AppKit
import ExtensionFoundation
import SwiftUI


// MARK: - Sidebar Extension XPC Host
@MainActor
final class CMUXSidebarExtensionHostXPC {
    private static let untrustedScopes: Set<CmuxExtensionScope> = []
    private static let untrustedActionScopes: Set<CmuxExtensionActionScope> = []
    private static let manifestRequestTimeoutNanoseconds: UInt64 = 5_000_000_000

    private var connection: NSXPCConnection?
    private var extensionProxy: CMUXSidebarExtensionXPC?
    private var exportedObject: CMUXSidebarHostXPCObject?
    private var snapshotProvider: (() -> CmuxSidebarSnapshot)?
    private var actionHandler: ((CmuxSidebarAction) -> CmuxSidebarActionResult)?
    private var allowedScopes = untrustedScopes
    private var allowedActionScopes = untrustedActionScopes
    private var connectionGeneration: UInt64 = 0
    private var bundleIdentifier: String?
    private var currentManifest: CmuxExtensionManifest?
    private var onGrantChanged: ((CMUXSidebarExtensionEffectiveGrant?) -> Void)?
    private var onManifestBlocked: ((String?) -> Void)?
    private var awaitingManifestGeneration: UInt64?
    private var manifestRequestTimeoutTask: Task<Void, Never>?
    private let grantStore = CMUXSidebarExtensionGrantStore()

    var currentEffectiveGrant: CMUXSidebarExtensionEffectiveGrant? {
        guard let bundleIdentifier, let currentManifest else { return nil }
        return grantStore.effectiveGrant(bundleIdentifier: bundleIdentifier, manifest: currentManifest)
    }

    func update(
        snapshotProvider: @escaping @MainActor () -> CmuxSidebarSnapshot,
        actionHandler: @escaping @MainActor (CmuxSidebarAction) -> CmuxSidebarActionResult
    ) {
        self.snapshotProvider = snapshotProvider
        self.actionHandler = actionHandler
        exportedObject?.actionHandler = scopedActionHandler(actionHandler)
        updateExportedSnapshotFilter()
    }

    func attach(
        connection: NSXPCConnection,
        bundleIdentifier: String,
        snapshotProvider: @escaping @MainActor () -> CmuxSidebarSnapshot,
        actionHandler: @escaping @MainActor (CmuxSidebarAction) -> CmuxSidebarActionResult,
        onGrantChanged: @escaping @MainActor (CMUXSidebarExtensionEffectiveGrant?) -> Void,
        onManifestBlocked: @escaping @MainActor (String?) -> Void
    ) {
        invalidate()
        connectionGeneration += 1
        let generation = connectionGeneration
        let exportedObject = CMUXSidebarHostXPCObject(
            snapshotProvider: { Self.untrustedSnapshot(from: snapshotProvider()) },
            actionHandler: scopedActionHandler(actionHandler),
            onAcceptedAction: { [weak self] in
                self?.sendSnapshotDidChange()
            },
            isCurrentGeneration: { [weak self] in
                self?.connectionGeneration == generation
            }
        )
        connection.exportedInterface = NSXPCInterface(with: CMUXSidebarHostXPC.self)
        connection.exportedObject = exportedObject
        connection.remoteObjectInterface = NSXPCInterface(with: CMUXSidebarExtensionXPC.self)
        connection.invalidationHandler = { [weak self, generation] in
            Task { @MainActor in
                self?.clearConnection(ifCurrentGeneration: generation)
            }
        }
        connection.interruptionHandler = { [weak self, generation] in
            Task { @MainActor in
                self?.clearProxy(ifCurrentGeneration: generation)
            }
        }
        self.exportedObject = exportedObject
        self.snapshotProvider = snapshotProvider
        self.actionHandler = actionHandler
        self.connection = connection
        self.bundleIdentifier = bundleIdentifier
        self.currentManifest = nil
        self.onGrantChanged = onGrantChanged
        self.onManifestBlocked = onManifestBlocked
        self.allowedScopes = Self.untrustedScopes
        self.allowedActionScopes = Self.untrustedActionScopes
        self.extensionProxy = connection.remoteObjectProxy as? CMUXSidebarExtensionXPC
        connection.resume()
        requestManifestThenSendInitialSnapshot(generation: generation)
    }

    func sendSnapshotDidChange() {
        guard let extensionProxy, let snapshotProvider else { return }
        do {
            extensionProxy.sidebarSnapshotDidChange(try CmuxSidebarXPCCodec.encodeSnapshot(filteredSnapshot(from: snapshotProvider)))
        } catch {
#if DEBUG
            cmuxDebugLog("extension.sidebar.xpc.snapshot.encode.failed error=\(error.localizedDescription)")
#endif
        }
    }

    func invalidate() {
        connectionGeneration += 1
        let generation = connectionGeneration
        connection?.invalidate()
        clearConnection(ifCurrentGeneration: generation)
    }

    private func clearProxy(ifCurrentGeneration generation: UInt64) {
        guard connectionGeneration == generation else { return }
        extensionProxy = nil
        cancelManifestRequestTimeout()
        blockUntrustedExtension(reason: "connectionInterrupted")
        updateExportedSnapshotFilter()
    }

    private func clearConnection(ifCurrentGeneration generation: UInt64) {
        guard connectionGeneration == generation else { return }
        cancelManifestRequestTimeout()
        connection = nil
        extensionProxy = nil
        exportedObject = nil
        allowedScopes = Self.untrustedScopes
        allowedActionScopes = Self.untrustedActionScopes
        bundleIdentifier = nil
        currentManifest = nil
        onGrantChanged?(nil)
        onGrantChanged = nil
        onManifestBlocked?(nil)
        onManifestBlocked = nil
    }

    private func requestManifestThenSendInitialSnapshot(generation: UInt64) {
        guard let extensionProxy,
              let requestExtensionManifest = extensionProxy.requestExtensionManifest else {
            blockUntrustedExtension(reason: "missingManifest")
            updateExportedSnapshotFilter()
            return
        }
        beginManifestRequestTimeout(generation: generation)
        requestExtensionManifest { [weak self] payload, error in
            Task { @MainActor [generation] in
                guard let self else { return }
                guard self.connectionGeneration == generation else { return }
                guard self.awaitingManifestGeneration == generation else { return }
                self.cancelManifestRequestTimeout()
                if let payload {
                    do {
                        let manifest = try CmuxSidebarXPCCodec.decodeManifest(payload)
                        try validateSidebarManifest(manifest)
                        self.applyManifest(manifest)
                    } catch {
                        self.blockUntrustedExtension(reason: "invalidManifest")
#if DEBUG
                        cmuxDebugLog("extension.sidebar.manifest.invalid error=\(error.localizedDescription)")
#endif
                    }
                } else {
                    self.blockUntrustedExtension(reason: "manifestRequestFailed")
                    if let error {
#if DEBUG
                        cmuxDebugLog("extension.sidebar.manifest.failed error=\(error)")
#endif
                    }
                }
                self.updateExportedSnapshotFilter()
                if self.currentEffectiveGrant?.needsAdditionalApproval == false {
                    self.sendSnapshotDidChange()
                }
            }
        }
    }

    private func beginManifestRequestTimeout(generation: UInt64) {
        cancelManifestRequestTimeout()
        awaitingManifestGeneration = generation
        manifestRequestTimeoutTask = Task { @MainActor [weak self, generation] in
            do {
                try await Task.sleep(nanoseconds: Self.manifestRequestTimeoutNanoseconds)
            } catch {
                return
            }
            guard let self,
                  self.connectionGeneration == generation,
                  self.awaitingManifestGeneration == generation else { return }
            self.cancelManifestRequestTimeout()
            self.blockUntrustedExtension(reason: "manifestTimedOut")
            self.updateExportedSnapshotFilter()
        }
    }

    private func cancelManifestRequestTimeout() {
        awaitingManifestGeneration = nil
        manifestRequestTimeoutTask?.cancel()
        manifestRequestTimeoutTask = nil
    }

    func grantRequestedAccess(bundleIdentifier: String) {
        guard self.bundleIdentifier == bundleIdentifier, let currentManifest else { return }
        grantStore.grantRequestedAccess(bundleIdentifier: bundleIdentifier, manifest: currentManifest)
        applyManifest(currentManifest)
        sendSnapshotDidChange()
    }

    func revokeSensitiveAccess(bundleIdentifier: String) {
        guard self.bundleIdentifier == bundleIdentifier, let currentManifest else { return }
        grantStore.revokeSensitiveAccess(bundleIdentifier: bundleIdentifier, manifest: currentManifest)
        applyManifest(currentManifest)
        sendSnapshotDidChange()
    }

    private func applyManifest(_ manifest: CmuxExtensionManifest) {
        cancelManifestRequestTimeout()
        currentManifest = manifest
        guard let bundleIdentifier else {
            allowedScopes = Self.untrustedScopes
            allowedActionScopes = Self.untrustedActionScopes
            onGrantChanged?(nil)
            return
        }
        let effectiveGrant = grantStore.effectiveGrant(bundleIdentifier: bundleIdentifier, manifest: manifest)
        allowedScopes = effectiveGrant.readScopes
        allowedActionScopes = effectiveGrant.actionScopes
        onManifestBlocked?(nil)
        onGrantChanged?(effectiveGrant)
    }

    private func filteredSnapshot(from snapshotProvider: () -> CmuxSidebarSnapshot) -> CmuxSidebarSnapshot {
        snapshotProvider().filtered(for: allowedScopes, actionScopes: allowedActionScopes)
    }

    private func updateExportedSnapshotFilter() {
        guard let snapshotProvider else { return }
        exportedObject?.snapshotProvider = { [weak self] in
            guard let self else {
                return Self.untrustedSnapshot(from: snapshotProvider())
            }
            return filteredSnapshot(from: snapshotProvider)
        }
    }

    private func scopedActionHandler(
        _ actionHandler: @escaping @MainActor (CmuxSidebarAction) -> CmuxSidebarActionResult
    ) -> (@MainActor (CmuxSidebarAction) -> CmuxSidebarActionResult) {
        { [weak self] action in
            guard let self,
                  self.currentManifest != nil,
                  self.allowedActionScopes.isSuperset(of: action.requiredScopes) else {
                return CmuxSidebarActionResult(
                    accepted: false,
                    message: String(localized: "sidebar.extensions.action.scopeRejected", defaultValue: "Extension action is not granted")
                )
            }
            return actionHandler(action)
        }
    }

    private func blockUntrustedExtension(reason: String) {
        cancelManifestRequestTimeout()
        allowedScopes = Self.untrustedScopes
        allowedActionScopes = Self.untrustedActionScopes
        currentManifest = nil
        onGrantChanged?(nil)
        onManifestBlocked?(reason)
#if DEBUG
        cmuxDebugLog("extension.sidebar.manifest.blocked reason=\(reason)")
#endif
    }

    private static func untrustedSnapshot(from snapshot: CmuxSidebarSnapshot) -> CmuxSidebarSnapshot {
        CmuxSidebarSnapshot(
            apiVersion: snapshot.apiVersion,
            sequence: snapshot.sequence,
            selectedWorkspaceID: nil,
            workspaces: []
        )
    }
}

private final class CMUXSidebarHostXPCObject: NSObject, CMUXSidebarHostXPC {
    @MainActor var snapshotProvider: () -> CmuxSidebarSnapshot
    @MainActor var actionHandler: (CmuxSidebarAction) -> CmuxSidebarActionResult
    @MainActor private var onAcceptedAction: () -> Void
    @MainActor private var isCurrentGeneration: () -> Bool

    @MainActor
    init(
        snapshotProvider: @escaping @MainActor () -> CmuxSidebarSnapshot,
        actionHandler: @escaping @MainActor (CmuxSidebarAction) -> CmuxSidebarActionResult,
        onAcceptedAction: @escaping @MainActor () -> Void,
        isCurrentGeneration: @escaping @MainActor () -> Bool
    ) {
        self.snapshotProvider = snapshotProvider
        self.actionHandler = actionHandler
        self.onAcceptedAction = onAcceptedAction
        self.isCurrentGeneration = isCurrentGeneration
    }

    func requestSidebarSnapshot(reply: @escaping (NSData?, NSString?) -> Void) {
        Task { @MainActor in
            guard isCurrentGeneration() else {
                reply(nil, String(localized: "sidebar.extensions.action.staleConnection", defaultValue: "Extension connection is no longer active") as NSString)
                return
            }
            do {
                reply(try CmuxSidebarXPCCodec.encodeSnapshot(snapshotProvider()), nil)
            } catch {
                reply(nil, error.localizedDescription as NSString)
            }
        }
    }

    func performSidebarAction(_ payload: NSData, reply: @escaping (NSData?, NSString?) -> Void) {
        Task { @MainActor in
            guard isCurrentGeneration() else {
                reply(nil, String(localized: "sidebar.extensions.action.staleConnection", defaultValue: "Extension connection is no longer active") as NSString)
                return
            }
            do {
                let action = try CmuxSidebarXPCCodec.decodeAction(payload)
                let result = actionHandler(action)
                reply(try CmuxSidebarXPCCodec.encodeActionResult(result), nil)
                if result.accepted {
                    onAcceptedAction()
                }
            } catch {
                reply(nil, error.localizedDescription as NSString)
            }
        }
    }
}
