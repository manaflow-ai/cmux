public import Foundation
@_spi(CmuxHostTransport) public import CmuxExtensionKit

/// `@MainActor` coordinator owning the `NSXPCConnection` lifecycle for a hosted
/// sidebar extension.
///
/// Drives manifest request/timeout, resolves the per-extension grant through a
/// ``CMUXSidebarExtensionGrantStore``, filters the snapshot to the granted
/// scopes, and exposes a scoped action handler. Localized wire messages and the
/// DEBUG event sink are injected from the app composition root (see
/// ``CMUXSidebarExtensionHostXPCStrings`` and `debugLog`) so the package never
/// references the app's `String(localized:)` catalog or `cmuxDebugLog`.
@_spi(CmuxHostTransport)
@MainActor
public final class CMUXSidebarExtensionHostXPC {
    private static let untrustedScopes: Set<CmuxExtensionScope> = []
    private static let untrustedActionScopes: Set<CmuxExtensionActionScope> = []
    private static let manifestRequestTimeoutNanoseconds: UInt64 = 5_000_000_000

    private var connection: NSXPCConnection?
    private var extensionProxy: (any CMUXSidebarExtensionXPC)?
    private var exportedObject: CMUXSidebarHostXPCObject?
    private var snapshotProvider: (@MainActor @Sendable () -> CmuxSidebarSnapshot)?
    private var actionHandler: (@MainActor @Sendable (CmuxSidebarAction) -> CmuxSidebarActionResult)?
    private var allowedScopes = untrustedScopes
    private var allowedActionScopes = untrustedActionScopes
    private var connectionGeneration: UInt64 = 0
    private var bundleIdentifier: String?
    private var currentManifest: CmuxExtensionManifest?
    private var onGrantChanged: (@MainActor @Sendable (CMUXSidebarExtensionEffectiveGrant?) -> Void)?
    private var onManifestBlocked: (@MainActor @Sendable (CMUXSidebarExtensionBlockedReason?) -> Void)?
    private var awaitingManifestGeneration: UInt64?
    private var manifestRequestTimeoutTask: Task<Void, Never>?
    private let grantStore = CMUXSidebarExtensionGrantStore()
    private let strings: CMUXSidebarExtensionHostXPCStrings

    /// DEBUG-only sink injected by the app composition root so the coordinator
    /// keeps emitting `extension.sidebar.*` events without the package depending
    /// on the app's `cmuxDebugLog`. `nil` in release.
    private let debugLog: ((_ message: String) -> Void)?

    public init(
        strings: CMUXSidebarExtensionHostXPCStrings,
        debugLog: ((_ message: String) -> Void)? = nil
    ) {
        self.strings = strings
        self.debugLog = debugLog
    }

    public var currentEffectiveGrant: CMUXSidebarExtensionEffectiveGrant? {
        guard let bundleIdentifier, let currentManifest else { return nil }
        return grantStore.effectiveGrant(bundleIdentifier: bundleIdentifier, manifest: currentManifest)
    }

    public func update(
        snapshotProvider: @escaping @MainActor @Sendable () -> CmuxSidebarSnapshot,
        actionHandler: @escaping @MainActor @Sendable (CmuxSidebarAction) -> CmuxSidebarActionResult
    ) {
        self.snapshotProvider = snapshotProvider
        self.actionHandler = actionHandler
        exportedObject?.actionHandler = scopedActionHandler(actionHandler)
        updateExportedSnapshotFilter()
    }

    public func attach(
        connection: NSXPCConnection,
        bundleIdentifier: String,
        snapshotProvider: @escaping @MainActor @Sendable () -> CmuxSidebarSnapshot,
        actionHandler: @escaping @MainActor @Sendable (CmuxSidebarAction) -> CmuxSidebarActionResult,
        onGrantChanged: @escaping @MainActor @Sendable (CMUXSidebarExtensionEffectiveGrant?) -> Void,
        onManifestBlocked: @escaping @MainActor @Sendable (CMUXSidebarExtensionBlockedReason?) -> Void
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
            },
            staleConnection: strings.staleConnection
        )
        connection.exportedInterface = NSXPCInterface(with: (any CMUXSidebarHostXPC).self)
        connection.exportedObject = exportedObject
        connection.remoteObjectInterface = NSXPCInterface(with: (any CMUXSidebarExtensionXPC).self)
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
        self.extensionProxy = connection.remoteObjectProxy as? any CMUXSidebarExtensionXPC
        connection.resume()
        requestManifestThenSendInitialSnapshot(generation: generation)
    }

    public func sendSnapshotDidChange() {
        guard let extensionProxy, let snapshotProvider else { return }
        do {
            extensionProxy.sidebarSnapshotDidChange(try CmuxSidebarXPCCodec.encodeSnapshot(filteredSnapshot(from: snapshotProvider)))
        } catch {
            debugLog?("extension.sidebar.xpc.snapshot.encode.failed error=\(error.localizedDescription)")
        }
    }

    public func invalidate() {
        connectionGeneration += 1
        let generation = connectionGeneration
        connection?.invalidate()
        clearConnection(ifCurrentGeneration: generation)
    }

    private func clearProxy(ifCurrentGeneration generation: UInt64) {
        guard connectionGeneration == generation else { return }
        extensionProxy = nil
        cancelManifestRequestTimeout()
        blockUntrustedExtension(reason: .connectionInterrupted)
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
            blockUntrustedExtension(reason: .missingManifest)
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
                        self.blockUntrustedExtension(reason: .invalidManifest)
                        self.debugLog?("extension.sidebar.manifest.invalid error=\(error.localizedDescription)")
                    }
                } else {
                    self.blockUntrustedExtension(reason: .manifestRequestFailed)
                    if let error {
                        self.debugLog?("extension.sidebar.manifest.failed error=\(error)")
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
            self.blockUntrustedExtension(reason: .manifestTimedOut)
            self.updateExportedSnapshotFilter()
        }
    }

    private func cancelManifestRequestTimeout() {
        awaitingManifestGeneration = nil
        manifestRequestTimeoutTask?.cancel()
        manifestRequestTimeoutTask = nil
    }

    public func grantRequestedAccess(bundleIdentifier: String) {
        guard self.bundleIdentifier == bundleIdentifier, let currentManifest else { return }
        grantStore.grantRequestedAccess(bundleIdentifier: bundleIdentifier, manifest: currentManifest)
        applyManifest(currentManifest)
        sendSnapshotDidChange()
    }

    public func revokeSensitiveAccess(bundleIdentifier: String) {
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

    private func filteredSnapshot(
        from snapshotProvider: @MainActor @Sendable () -> CmuxSidebarSnapshot
    ) -> CmuxSidebarSnapshot {
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
        _ actionHandler: @escaping @MainActor @Sendable (CmuxSidebarAction) -> CmuxSidebarActionResult
    ) -> (@MainActor @Sendable (CmuxSidebarAction) -> CmuxSidebarActionResult) {
        // Capture the rejection message by value so it is returned even when
        // `self` has deallocated, matching the original's constant
        // `String(localized:)` literal in the guard-else.
        let scopeRejected = strings.scopeRejected
        return { [weak self] action in
            guard let self,
                  self.currentManifest != nil,
                  self.allowedActionScopes.isSuperset(of: action.requiredScopes) else {
                return CmuxSidebarActionResult(
                    accepted: false,
                    message: scopeRejected
                )
            }
            return actionHandler(action)
        }
    }

    private func blockUntrustedExtension(reason: CMUXSidebarExtensionBlockedReason) {
        cancelManifestRequestTimeout()
        allowedScopes = Self.untrustedScopes
        allowedActionScopes = Self.untrustedActionScopes
        currentManifest = nil
        onGrantChanged?(nil)
        onManifestBlocked?(reason)
        debugLog?("extension.sidebar.manifest.blocked reason=\(reason)")
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
