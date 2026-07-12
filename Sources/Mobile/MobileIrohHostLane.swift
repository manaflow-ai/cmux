import CMUXMobileCore
import CmuxMobileIrohTransport
import CmuxSettings
import CryptoKit
import Foundation
import OSLog
import Security

private let mobileIrohHostLog = Logger(subsystem: "dev.cmux", category: "mobile-host")

@MainActor
final class MobileIrohHostLane {
    private let maximumActiveConnectionCount: Int
    private let onRouteSetChanged: @MainActor () -> Void
    private let onReadinessChanged: @MainActor () -> Void
    private let onStreamAccepted: @MainActor (CmxIrohByteStream) -> Void

    private var listener: CmxIrohByteListener?
    private var acceptTask: Task<Void, Never>?
    private var acceptTasks: [UUID: Task<Void, Never>] = [:]
    private var acceptGeneration = UUID()
    private var route: CmxAttachRoute?
    private var appliedTransportMode: MobileTransportMode?
    private var appliedRelayURL: String?

    init(
        maximumActiveConnectionCount: Int,
        onRouteSetChanged: @escaping @MainActor () -> Void,
        onReadinessChanged: @escaping @MainActor () -> Void,
        onStreamAccepted: @escaping @MainActor (CmxIrohByteStream) -> Void
    ) {
        self.maximumActiveConnectionCount = maximumActiveConnectionCount
        self.onRouteSetChanged = onRouteSetChanged
        self.onReadinessChanged = onReadinessChanged
        self.onStreamAccepted = onStreamAccepted
    }

    var hasListener: Bool {
        listener != nil
    }

    var hasPublishedRoute: Bool {
        route != nil
    }

    var routes: [CmxAttachRoute] {
        route.map { [$0] } ?? []
    }

    func recordAppliedTransportMode(_ mode: MobileTransportMode, relayURL: String?) {
        appliedTransportMode = mode
        appliedRelayURL = relayURL
    }

    func clearAppliedTransportMode() {
        appliedTransportMode = nil
        appliedRelayURL = nil
    }

    func requiresRestart(mode: MobileTransportMode, relayURL: String?) -> Bool {
        mode != appliedTransportMode || (mode == .ownRelay && relayURL != appliedRelayURL)
    }

    /// Binds the iroh endpoint and starts accepting, merging its route into the
    /// published set. Idempotent; a no-op when disabled or already bound.
    func startIfEnabled(mode: MobileTransportMode, relayURL: String?) {
        guard mode.usesIroh, listener == nil else { return }
        // ownRelay requires the user's relay URL. Without a valid one, don't bind
        // against the default fleet (that would be silent cmuxRelay behavior the
        // picker doesn't promise): leave the lane down so the pairing window
        // surfaces "configure your relay URL" instead of a misleading code.
        if mode == .ownRelay, relayURL == nil {
            mobileIrohHostLog.error("iroh host: ownRelay selected but no valid relay URL configured; not binding")
            return
        }
        // A persisted Keychain key gives the Mac a stable EndpointId across
        // launches (the per-device identity client pinning relies on).
        // enableRelay so off-LAN phones can dial; relayURL is set only in
        // ownRelay mode (nil keeps the default cmux/n0 relay fleet).
        let listener = CmxIrohByteListener(
            secretKey: Self.loadOrCreateIrohSecretKey(),
            enableRelay: true,
            relayURL: relayURL,
            // TODO: mint via web API.
            relayAuthToken: nil
        )
        let generation = UUID()
        acceptGeneration = generation
        self.listener = listener
        acceptTask = Task { @MainActor [weak self] in
            do {
                try await listener.start()
            } catch {
                mobileIrohHostLog.error("iroh host listener failed to bind: \(String(describing: error), privacy: .public)")
                // Only the CURRENT generation may clear the lane. A bind that
                // returns after a mode change (stop() rotated the generation and
                // started a replacement listener) throws alreadyClosed/cancelled
                // here; without this guard its catch would null out the fresh
                // replacement listener, leaving pairing dead. Close the stale
                // listener (idempotent) and leave the current one intact.
                guard let self,
                      self.listener === listener,
                      self.acceptGeneration == generation
                else {
                    await listener.close()
                    return
                }
                // Clear the wedged listener so a later start() can retry, and
                // release any pairing-readiness waiter instead of stalling it for
                // the full timeout.
                self.listener = nil
                self.onReadinessChanged()
                return
            }
            guard let self,
                  self.listener === listener,
                  self.acceptGeneration == generation,
                  !Task.isCancelled
            else {
                await listener.close()
                return
            }
            if let json = await listener.routeJSON() {
                mobileIrohHostLog.info("iroh host listener ready; publishing dial-by-EndpointId route \(json, privacy: .public)")
                self.adoptRoute(from: json)
            } else {
                mobileIrohHostLog.error("iroh host listener bound but produced no route")
            }
            self.refillAcceptTasks(listener: listener, generation: generation)
        }
    }

    func stop() {
        acceptTask?.cancel()
        acceptTask = nil
        acceptGeneration = UUID()
        let tasks = acceptTasks.values
        acceptTasks.removeAll()
        for task in tasks {
            task.cancel()
        }
        if let listener {
            Task { await listener.close() }
        }
        listener = nil
        route = nil
    }

    /// Decodes the listener's `CmxAttachRoute`-shaped route JSON and republishes
    /// the status so the iroh route reaches tickets, the registry, and QR.
    private func adoptRoute(from routeJSON: String) {
        guard let data = routeJSON.data(using: .utf8),
              let decodedRoute = try? JSONDecoder().decode(CmxAttachRoute.self, from: data)
        else {
            return
        }
        // Prefer iroh over Tailscale on capable phones (lower priority wins).
        route = (try? CmxAttachRoute(
            id: decodedRoute.id,
            kind: decodedRoute.kind,
            endpoint: decodedRoute.endpoint,
            priority: -1
        )) ?? decodedRoute
        // Publishing here is what makes the iroh route reachable to tickets/QR,
        // and it releases any pairing-readiness waiter (see ensureListeningAndReady).
        onRouteSetChanged()
        onReadinessChanged()
    }

    private func refillAcceptTasks(listener: CmxIrohByteListener, generation: UUID) {
        guard self.listener === listener, acceptGeneration == generation else { return }
        while acceptTasks.count < maximumActiveConnectionCount {
            startAcceptTask(listener: listener, generation: generation)
        }
    }

    private func startAcceptTask(listener: CmxIrohByteListener, generation: UUID) {
        let taskID = UUID()
        acceptTasks[taskID] = Task { [weak self, listener] in
            let acceptedStream: CmxIrohByteStream?
            do {
                acceptedStream = try await listener.accept(timeoutMilliseconds: 0)
            } catch {
                acceptedStream = nil
            }
            await MainActor.run {
                self?.finishAcceptTask(
                    taskID,
                    listener: listener,
                    generation: generation,
                    stream: acceptedStream
                )
            }
        }
    }

    private func finishAcceptTask(
        _ taskID: UUID,
        listener: CmxIrohByteListener,
        generation: UUID,
        stream: CmxIrohByteStream?
    ) {
        acceptTasks[taskID] = nil
        guard self.listener === listener, acceptGeneration == generation else {
            if let stream {
                Task { await stream.close() }
            }
            return
        }
        if let stream {
            accept(stream)
        }
        refillAcceptTasks(listener: listener, generation: generation)
    }

    private func accept(_ stream: CmxIrohByteStream) {
        // The host's shared registerConnection enforces the limit against the
        // registry; this is a cheap pre-check to avoid building a session we'd
        // only reject.
        guard MobileHostConnectionRegistry.shared.count < maximumActiveConnectionCount else {
            mobileIrohHostLog.error("mobile host rejected iroh connection because active connection limit was reached")
            Task { await stream.close() }
            return
        }
        onStreamAccepted(stream)
    }

    private nonisolated static let secretKeyKeychainService = "dev.cmux.iroh.host-secret-key"
    private nonisolated static let secretKeyByteCount = 32

    /// The Mac's persisted iroh secret key, so the Mac keeps ONE stable
    /// EndpointId across launches (a rotated id kills every stored/registry
    /// iroh route on the phone). Never synced (a synced key would let two Macs
    /// claim one EndpointId).
    ///
    /// Storage is deliberately NOT the legacy file-based login keychain: an
    /// item created there by an earlier, differently-signed build makes
    /// securityd park `SecItemCopyMatching` behind a user-consent dialog
    /// (`SecItemCopyMatching_osx` ignores `kSecUseAuthenticationUI`), which
    /// wedged `MobileHostService.start()` on launch and rotated the identity
    /// on every re-signed dev build. Instead:
    ///
    /// 1. The DATA PROTECTION keychain (`kSecUseDataProtectionKeychain`),
    ///    which is access-group scoped and never shows consent dialogs, for
    ///    builds entitled to use it (production signing).
    /// 2. A 0600 key file under Application Support, namespaced by bundle id
    ///    (two tagged dev apps must not share one EndpointId), for dev builds
    ///    whose ad-hoc signature has no application identifier
    ///    (`errSecMissingEntitlement`). Same protection class as `~/.ssh`
    ///    keys, and - unlike an ACL'd keychain item - survives re-signs.
    ///
    /// A fresh ephemeral key is returned only when both stores fail, so the
    /// host still binds.
    ///
    /// Deliberately NO migration read of the legacy login-keychain item: that
    /// read is the unbounded consent-dialog hang (the CSSM path has no timeout
    /// and ignores `kSecUseAuthenticationUI`), and no RELEASED build ever wrote
    /// the legacy item - iroh has only shipped in dev builds - so the one-time
    /// identity rotation on upgrade affects dev dogfooders only and self-heals
    /// via re-pair or the presence route push. The orphan is left untouched.
    private nonisolated static func loadOrCreateIrohSecretKey() -> [UInt8] {
        // 1. Data-protection keychain (prompt-free by construction).
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: secretKeyKeychainService,
            kSecUseDataProtectionKeychain as String: true,
        ]
        var readQuery = baseQuery
        readQuery[kSecReturnData as String] = true
        readQuery[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let readStatus = SecItemCopyMatching(readQuery as CFDictionary, &result)
        if readStatus == errSecSuccess,
           let data = result as? Data,
           data.count == secretKeyByteCount {
            return [UInt8](data)
        }

        // 2. Dev key file (per bundle id).
        if let fileKey = try? Data(contentsOf: secretKeyFileURL()),
           fileKey.count == secretKeyByteCount {
            return [UInt8](fileKey)
        }

        // First run (or unreadable state): mint a key and persist it.
        let key = Data(Curve25519.Signing.PrivateKey().rawRepresentation)
        var insert = baseQuery
        insert[kSecValueData as String] = key
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        var writeStatus = SecItemAdd(insert as CFDictionary, nil)
        if writeStatus == errSecDuplicateItem {
            // An item exists but did not read back cleanly: replace its value.
            _ = SecItemDelete(baseQuery as CFDictionary)
            writeStatus = SecItemAdd(insert as CFDictionary, nil)
        }
        if writeStatus == errSecSuccess {
            return [UInt8](key)
        }
        // Unentitled (dev) build: fall back to the key file.
        do {
            let url = try secretKeyFileURLCreatingDirectory()
            try key.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path
            )
            return [UInt8](key)
        } catch {
            mobileIrohHostLog.error(
                "failed to persist iroh secret key (keychain \(writeStatus, privacy: .public), file \(String(describing: error), privacy: .public)); using ephemeral"
            )
            return [UInt8](key)
        }
    }

    /// The dev fallback key file: Application Support/cmux/, namespaced by
    /// bundle id so concurrently-installed tagged dev builds keep distinct
    /// iroh identities.
    private nonisolated static func secretKeyFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let bundleID = Bundle.main.bundleIdentifier ?? "com.cmuxterm.app.unknown"
        return base
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("iroh-host-secret-key-\(bundleID)")
    }

    private nonisolated static func secretKeyFileURLCreatingDirectory() throws -> URL {
        let url = secretKeyFileURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return url
    }
}

extension MobileHostService {
    /// Whether the iroh host accept lane is enabled, i.e. the chosen transport
    /// mode is an iroh mode (`cmuxRelay` or `ownRelay`). When on, the Mac binds
    /// an iroh endpoint and advertises a dial-by-EndpointId route.
    nonisolated static func isIrohHostEnabled(defaults: UserDefaults = .standard) -> Bool {
        currentTransportMode(defaults: defaults).usesIroh
    }

    /// The custom relay URL the iroh lane should home on. Non-nil only in
    /// `.ownRelay` mode with a non-empty configured URL; `.cmuxRelay` returns nil
    /// so the endpoint uses the default cmux/n0 relay fleet.
    nonisolated static func irohRelayURL(defaults: UserDefaults = .standard) -> String? {
        guard currentTransportMode(defaults: defaults) == .ownRelay else { return nil }
        let url = defaults.string(forKey: SettingCatalog().mobile.iOSIrohRelayURL.userDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (url?.isEmpty == false) ? url : nil
    }
}
