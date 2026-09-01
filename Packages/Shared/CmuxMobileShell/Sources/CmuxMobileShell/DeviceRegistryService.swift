public import CMUXMobileCore
public import CmuxMobileShellModel
public import Foundation
import os
#if canImport(UIKit)
import UIKit
#endif

private let deviceRegistryLog = Logger(subsystem: "com.cmuxterm.app", category: "DeviceRegistry")

/// HTTP client for the team-scoped device registry (`/api/devices`).
///
/// Looks up fresher attach routes for a paired Mac on reload. P1 only needs the
/// phone to *read* the team's Macs; registering the phone itself as a `device`
/// row is deferred to the key-pinning phase (a phone row only matters once it
/// anchors a pinned key for revoke). `deviceID` is already plumbed here so that
/// phase has the persisted identity ready.
///
/// Auth mirrors ``PushRegistrationService``: native calls send
/// `Authorization: Bearer <access>` + `X-Stack-Refresh-Token: <refresh>`, plus an
/// optional `X-Cmux-Team-Id` so the server scopes to the chosen team (defaults to
/// the Stack-selected team when omitted). Tokens are supplied through injected
/// Sendable closures so this service needs no dependency on the auth package.
///
/// Every call is best-effort and failure-tolerant: a thrown/timed-out request
/// yields `nil` so reconnect falls back to locally persisted routes and pairing
/// survives the registry being down.
public actor DeviceRegistryService: DeviceRegistryRefreshing {
    /// Supplies the bearer/refresh tokens for an authenticated request, or `nil`
    /// when there is no valid session.
    public struct TokenSource: Sendable {
        public var accessToken: @Sendable () async -> String?
        public var refreshToken: @Sendable () async -> String?

        public init(
            accessToken: @escaping @Sendable () async -> String?,
            refreshToken: @escaping @Sendable () async -> String?
        ) {
            self.accessToken = accessToken
            self.refreshToken = refreshToken
        }
    }

    private let apiBaseURL: String
    private let deviceID: String
    private let tokenSource: TokenSource
    private let teamIDProvider: @Sendable () async -> String?
    private let session: CmxCredentialedHTTPSession
    private let requestTimeout: TimeInterval
    private struct RegistryResponse: Sendable {
        let data: Data
        let statusCode: Int
    }
    private struct RegistryRequestScope: Hashable, Sendable {
        let accessToken: String
        let refreshToken: String
        let teamID: String?
    }
    private struct RegistryListRequest: Sendable {
        let request: URLRequest
        let scope: RegistryRequestScope
    }
    private struct InFlightRegistryRequest: Sendable {
        let id: UUID
        let task: Task<RegistryResponse?, Never>
    }
    private var listResponseTasks: [RegistryRequestScope: InFlightRegistryRequest] = [:]

    /// - Parameters:
    ///   - apiBaseURL: The cmux web API base URL (no trailing slash).
    ///   - deviceID: This iOS device's registry id (``deviceID(defaults:)``).
    ///   - tokenSource: Supplies the Stack access/refresh tokens.
    ///   - teamIDProvider: Supplies the team id to scope to, or `nil` to let the
    ///     server use the Stack-selected team.
    ///   - sessionConfiguration: URL loading configuration. Redirect rejection,
    ///     cookie isolation, and cache isolation are enforced by the service.
    ///   - requestTimeout: Per-request deadline, bounding the worst-case latency
    ///     of a registry call so it never stalls the reconnect refresh.
    public init(
        apiBaseURL: String,
        deviceID: String,
        tokenSource: TokenSource,
        teamIDProvider: @escaping @Sendable () async -> String? = { nil },
        sessionConfiguration: sending URLSessionConfiguration = .ephemeral,
        requestTimeout: TimeInterval = 5
    ) {
        self.apiBaseURL = apiBaseURL
        self.deviceID = deviceID
        self.tokenSource = tokenSource
        self.teamIDProvider = teamIDProvider
        self.session = CmxCredentialedHTTPSession(configuration: sessionConfiguration)
        self.requestTimeout = requestTimeout
    }

    // MARK: - Device identity

    private static let deviceIDKey = "cmux.deviceRegistry.iosDeviceID"

    /// This iOS device's stable cmux identity for the device registry.
    ///
    /// A cmux-GENERATED persisted UUID (NOT `identifierForVendor`, which resets
    /// when the last cmux app is removed, and NOT a hardware fingerprint).
    /// Stored in a device-only Keychain item so it survives an app reinstall
    /// (iOS `UserDefaults` does not): the iroh binding slot is keyed on
    /// `(user, device, tag)`, so a returning phone must present the same device
    /// id to overwrite its own binding in place instead of stranding a new one.
    /// The `UserDefaults` mirror is trusted only when it provably belongs to
    /// THIS physical device: `UserDefaults` travels in device backups onto NEW
    /// phones while the `ThisDeviceOnly` Keychain item does not, so a mirror is
    /// adopted on authoritative Keychain absence only when its recorded device
    /// witness (`identifierForVendor`) matches this device or predates the
    /// witness mechanism (the in-place upgrade population). Mirrors the Mac
    /// side's `MobileHostIdentity.deviceID()`.
    ///
    /// This is the best-effort read used by non-binding callers (the device
    /// registry HTTP client, which only reads the team's Macs). It never returns
    /// `nil`: when the store is unreadable and no mirror exists it yields a
    /// process-stable ephemeral id. Do NOT use it to register an iroh binding —
    /// that path must use ``durableDeviceID(defaults:)`` and defer while it is
    /// `nil`, so a throwaway id never becomes a stranded `(user, device, tag)`
    /// binding.
    /// - Parameters:
    ///   - defaults: Legacy persistence store (injected for tests).
    ///   - evidence: Same-device evidence probe consulted for a mirror with no
    ///     recorded witness (see ``SameDeviceEvidenceProbing``). Every
    ///     production caller of one identity must pass the SAME probe, or
    ///     resolution becomes ordering-dependent.
    @MainActor
    public static func deviceID(
        defaults: UserDefaults = .standard,
        evidence: any SameDeviceEvidenceProbing = IrohEndpointIdentityEvidenceProbe()
    ) -> String {
        deviceID(
            store: defaultDeviceIdentityStore(defaults: defaults),
            defaults: defaults,
            deviceWitness: currentDeviceWitness(),
            evidence: evidence
        )
    }
    /// Testable core of ``deviceID(defaults:)`` with an injectable identity store.
    static func deviceID(
        store: any DeviceIdentityStoring,
        defaults: UserDefaults,
        deviceWitness: String? = nil,
        evidence: any SameDeviceEvidenceProbing = IrohEndpointIdentityEvidenceProbe()
    ) -> String {
        switch resolveDurableDeviceID(
            store: store,
            defaults: defaults,
            deviceWitness: deviceWitness,
            evidence: evidence
        ) {
        case .durable(let id):
            return id
        case .unavailable:
            // The store is unreadable with no mirror, or a fresh mint could not be
            // persisted. This best-effort path (registry reads only, never binding
            // registration) returns a process-stable ephemeral id so repeated
            // lookups agree within the launch; it is never persisted, so a later
            // launch that can read/persist mints the durable id.
            return ephemeralFallbackID
        }
    }

    /// This iOS device's *durable* identity for registering an iroh binding, or
    /// `nil` when no durable id can be produced right now.
    ///
    /// Returns `nil` in exactly two cases: the Keychain is unreadable (locked
    /// before first unlock) with no legacy `UserDefaults` mirror, or a fresh id
    /// could not be persisted to the Keychain. In both, using the value would
    /// create a throwaway `(user, device, tag)` binding that changes on the next
    /// launch and orphans the retained one. Callers must defer/retry activation
    /// until this returns a value instead of registering with an ephemeral id.
    /// - Parameters:
    ///   - defaults: Legacy persistence store (injected for tests).
    ///   - evidence: Same-device evidence probe consulted for a mirror with no
    ///     recorded witness (see ``SameDeviceEvidenceProbing``). Every
    ///     production caller of one identity must pass the SAME probe, or
    ///     resolution becomes ordering-dependent.
    @MainActor
    public static func durableDeviceID(
        defaults: UserDefaults = .standard,
        evidence: any SameDeviceEvidenceProbing = IrohEndpointIdentityEvidenceProbe()
    ) -> String? {
        durableDeviceID(
            store: defaultDeviceIdentityStore(defaults: defaults),
            defaults: defaults,
            deviceWitness: currentDeviceWitness(),
            evidence: evidence
        )
    }

    /// Off-main variant of ``durableDeviceID(defaults:evidence:)`` for callers
    /// that keep synchronous Keychain work off the UI actor: the witness
    /// (`identifierForVendor`, a MainActor read) is captured by the caller via
    /// ``currentDeviceWitness()`` and passed in, and the Keychain + defaults
    /// resolution runs on the calling executor.
    public static func durableDeviceID(
        defaults: UserDefaults = .standard,
        deviceWitness: String?,
        evidence: any SameDeviceEvidenceProbing = IrohEndpointIdentityEvidenceProbe()
    ) -> String? {
        durableDeviceID(
            store: defaultDeviceIdentityStore(defaults: defaults),
            defaults: defaults,
            deviceWitness: deviceWitness,
            evidence: evidence
        )
    }

    private static func defaultDeviceIdentityStore(
        defaults: UserDefaults
    ) -> any DeviceIdentityStoring {
        #if targetEnvironment(simulator)
        SimulatorDeviceIdentityStore(
            defaults: defaults,
            seededDeviceID: ProcessInfo.processInfo.environment[
                "CMUX_SIMULATOR_DEVICE_ID"
            ]
        )
        #else
        KeychainDeviceIdentityStore()
        #endif
    }
    /// Testable core of ``durableDeviceID(defaults:)`` with an injectable store.
    static func durableDeviceID(
        store: any DeviceIdentityStoring,
        defaults: UserDefaults,
        deviceWitness: String? = nil,
        evidence: any SameDeviceEvidenceProbing = IrohEndpointIdentityEvidenceProbe()
    ) -> String? {
        switch resolveDurableDeviceID(
            store: store,
            defaults: defaults,
            deviceWitness: deviceWitness,
            evidence: evidence
        ) {
        case .durable(let id):
            return id
        case .unavailable:
            return nil
        }
    }

    /// The outcome of resolving the device id from the authoritative store.
    enum DurableDeviceIDResolution: Equatable, Sendable {
        /// A durable id is available: read from the store, or freshly minted
        /// AND confirmed persisted. (While the store is temporarily unreadable,
        /// the legacy mirror of a continuing install also resolves as durable.)
        case durable(String)
        /// No durable id can be produced right now — the store is unreadable with
        /// no mirror, or a fresh mint could not be persisted.
        case unavailable
    }

    /// Resolve the device id from the authoritative store. Keychain is
    /// authoritative because it survives an app reinstall, keeping the iroh
    /// `(user, device, tag)` slot stable.
    ///
    /// Mirror trust is decided by ``mirrorVerdict``: the recorded
    /// `identifierForVendor` witness when the mirror carries one, falling back
    /// to the ThisDeviceOnly `evidence` probe for pre-witness mirrors (the
    /// in-place upgrade population). See that method for the full matrix.
    static func resolveDurableDeviceID(
        store: any DeviceIdentityStoring,
        defaults: UserDefaults,
        deviceWitness: String? = nil,
        evidence: any SameDeviceEvidenceProbing = IrohEndpointIdentityEvidenceProbe()
    ) -> DurableDeviceIDResolution {
        switch store.read() {
        case .found(let stored):
            let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                // Present but blank: treat as corrupt and re-mint/adopt.
                return adoptOrMintDeviceID(
                    store: store,
                    defaults: defaults,
                    deviceWitness: deviceWitness,
                    evidence: evidence
                )
            }
            // Re-mirror to UserDefaults (with this device's witness) so a later
            // downgrade finds the same id and a future restore of THIS backup
            // onto another phone is detectable. Writes are skipped when nothing
            // differs, so the authoritative read path stays free of churn.
            persistMirror(trimmed, deviceWitness: deviceWitness, defaults: defaults)
            return .durable(trimmed)
        case .absent:
            return adoptOrMintDeviceID(
                store: store,
                defaults: defaults,
                deviceWitness: deviceWitness,
                evidence: evidence
            )
        case .unavailable:
            // Fail closed: the store exists but is unreadable right now (a
            // background launch before first unlock leaves the Keychain locked).
            // Minting a new id here would strand the phone's existing
            // (user, device, tag) binding — the exact bug this store prevents.
            // Reuse the legacy UserDefaults mirror if its witness proves it was
            // written on THIS device (or a non-migrating artifact proves the
            // install is continuing here); otherwise report `.unavailable` so
            // binding registration defers.
            if let legacy = trimmedLegacyDeviceID(defaults),
               case .belongsToThisDevice = mirrorVerdict(
                   defaults: defaults,
                   currentWitness: deviceWitness,
                   evidence: evidence
               ) {
                return .durable(legacy)
            }
            return .unavailable
        }
    }

    /// Resolve an id when the Keychain authoritatively reports it ABSENT:
    /// adopt the `UserDefaults` mirror only when its recorded device witness
    /// proves it was written on THIS physical device, otherwise mint fresh.
    ///
    /// The mirror travels in device backups: restoring a backup onto a NEW
    /// phone carries `UserDefaults` over, while the `ThisDeviceOnly` Keychain
    /// item does not migrate. Blindly adopting the mirror would give TWO
    /// physical devices the same device id, and their registrations would
    /// fight over one `(user, device, tag)` binding slot on every ordinary
    /// phone upgrade. Blindly minting instead would change EVERY existing
    /// installation's identity once (the pre-Keychain in-place upgrade lands
    /// here with the mirror holding the id its live binding already uses) and
    /// strand all of their bindings. The witness — `identifierForVendor`, a
    /// per-device value a restored phone does not inherit — separates the two:
    /// matching witness means the same device, so adopt; a mismatched witness
    /// means a restored backup, so mint. A mirror with NO recorded witness
    /// predates this mechanism and proves nothing either way — every backup
    /// taken before the witness shipped restores in exactly that state — so it
    /// falls back to the ThisDeviceOnly `evidence` probe (the in-place upgrade
    /// population; see ``SameDeviceEvidenceProbing`` for the full matrix).
    /// Every mirror write from here on records the witness.
    ///
    /// Persistence goes through ``DeviceIdentityStoring/createOrAdopt(_:)``, which
    /// never overwrites a value a concurrent resolution already won, so two
    /// launches that each mint a different candidate converge on one id instead of
    /// the last writer clobbering the winner (which would strand the winner's
    /// binding on the next launch). A failed persist defers (`.unavailable`):
    /// an id only the reinstall-volatile mirror holds is not durable. An
    /// `.undecidable` mirror verdict (the evidence Keychain is locked before
    /// first unlock) also defers: minting there would rotate an upgrading
    /// device's identity, the exact bug this store prevents.
    private static func adoptOrMintDeviceID(
        store: any DeviceIdentityStoring,
        defaults: UserDefaults,
        deviceWitness: String?,
        evidence: any SameDeviceEvidenceProbing
    ) -> DurableDeviceIDResolution {
        let candidate: String
        if let legacy = trimmedLegacyDeviceID(defaults) {
            switch mirrorVerdict(
                defaults: defaults,
                currentWitness: deviceWitness,
                evidence: evidence
            ) {
            case .belongsToThisDevice:
                candidate = legacy
            case .foreign:
                // Remove the untrusted mirror (and its foreign witness) BEFORE
                // minting, so even a failed persist leaves no unsafe value for
                // a later resolution to trust.
                defaults.removeObject(forKey: deviceIDKey)
                defaults.removeObject(forKey: deviceWitnessKey)
                candidate = UUID().uuidString.lowercased()
            case .undecidable:
                return .unavailable
            }
        } else {
            candidate = UUID().uuidString.lowercased()
        }
        guard let winner = store.createOrAdopt(candidate) else {
            return .unavailable
        }
        persistMirror(winner, deviceWitness: deviceWitness, defaults: defaults)
        return .durable(winner)
    }

    /// The trust decision for a `UserDefaults` mirror when the authoritative
    /// Keychain id is absent or unreadable.
    private enum MirrorVerdict {
        /// Provably written on this physical device: adopt it.
        case belongsToThisDevice
        /// Provably (or presumptively) arrived in a backup from another phone:
        /// mint fresh instead.
        case foreign
        /// The evidence Keychain cannot be read right now (locked before first
        /// unlock): neither adopt nor mint — defer resolution.
        case undecidable
    }

    /// Decide whether the mirror belongs to this physical device.
    ///
    /// Witness first: a recorded `identifierForVendor` that matches the current
    /// one proves same-device (vendor ids never repeat across devices) with no
    /// Keychain read; a recorded witness that MISMATCHES proves a restored
    /// backup and overrides the evidence probe — the probe can report
    /// `.present` from a stale ThisDeviceOnly item left by a PREVIOUS install
    /// on this phone (Keychain items outlive app deletion), while the mirror
    /// itself arrived in another phone's backup. When the witness cannot
    /// decide (none recorded — the pre-witness population — or the current
    /// witness is unreadable), fall back to the probe's matrix.
    private static func mirrorVerdict(
        defaults: UserDefaults,
        currentWitness: String?,
        evidence: any SameDeviceEvidenceProbing
    ) -> MirrorVerdict {
        if let recorded = defaults.string(forKey: deviceWitnessKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !recorded.isEmpty,
            let currentWitness {
            return recorded == currentWitness ? .belongsToThisDevice : .foreign
        }
        switch evidence.probe() {
        case .present:
            return .belongsToThisDevice
        case .absent:
            return .foreign
        case .unavailable:
            return .undecidable
        }
    }

    /// Write the mirror and (when known) this device's witness, skipping
    /// no-op writes so the read path stays free of churn.
    private static func persistMirror(
        _ id: String,
        deviceWitness: String?,
        defaults: UserDefaults
    ) {
        if defaults.string(forKey: deviceIDKey) != id {
            defaults.set(id, forKey: deviceIDKey)
        }
        if let deviceWitness, defaults.string(forKey: deviceWitnessKey) != deviceWitness {
            defaults.set(deviceWitness, forKey: deviceWitnessKey)
        }
    }

    /// The per-device witness recorded beside the mirror: a value present on
    /// THIS device that a backup restored onto another phone does not carry
    /// forward. `identifierForVendor` resets on a new device (and when the
    /// vendor's last app is removed — which also clears `UserDefaults`, so the
    /// mirror disappears with it and no stale comparison survives).
    ///
    /// Public so an off-main resolver can capture the witness with one MainActor
    /// hop and run the Keychain resolution on its own executor.
    @MainActor
    public static func currentDeviceWitness() -> String? {
        #if canImport(UIKit)
        return UIDevice.current.identifierForVendor?.uuidString
        #else
        return nil
        #endif
    }

    static let deviceWitnessKey = "cmux.deviceRegistry.iosDeviceIDWitness"

    /// The legacy `UserDefaults` device id, trimmed, or `nil` when absent/blank.
    private static func trimmedLegacyDeviceID(_ defaults: UserDefaults) -> String? {
        guard let legacy = defaults.string(forKey: deviceIDKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !legacy.isEmpty else {
            return nil
        }
        return legacy
    }

    /// A per-process fallback id, used only by the best-effort ``deviceID`` read
    /// path when the identity store is unreadable and no legacy mirror exists.
    /// Stable within a launch so repeated lookups agree, but never persisted, so
    /// the next launch that can read the store adopts or mints the durable id
    /// instead of freezing this throwaway value.
    private static let ephemeralFallbackID = UUID().uuidString.lowercased()

    // MARK: - Reconnect route policy (pure, testable)

    /// Choose the routes to persist for the next reconnect.
    ///
    /// The reconnect path connects on `local` routes immediately (no added
    /// latency on the common case) and only *replaces* the persisted routes when
    /// the registry returns a usable, different set, so a stale-route Mac gets
    /// rescued on the next reconnect trigger. Returns `nil` to signal "no change
    /// needed" (registry unavailable, empty, or identical), letting callers skip
    /// a redundant store write and fall back to the locally persisted routes.
    public static func selectReconnectRoutes(
        local: [CmxAttachRoute],
        registry: [CmxAttachRoute]?
    ) -> [CmxAttachRoute]? {
        guard let registry, !registry.isEmpty else { return nil }
        guard registry != local else { return nil }
        // Keep a locally persisted Tailscale destination alongside a newly
        // published Iroh route. The local route may carry the pre-Iroh grant
        // needed to reconnect an older Mac while the registry has already
        // converged on Iroh-only publication.
        guard registry.contains(where: { $0.kind == .iroh }) else {
            return registry
        }
        // The registry remains authoritative when it publishes any current
        // Tailscale route. Only an Iroh-only response needs one legacy local
        // fallback for Macs paired before the Iroh migration.
        guard registry.allSatisfy({ $0.kind == .iroh }) else {
            return registry
        }
        var selected = registry
        if let legacyTailscale = local.first(where: { $0.kind == .tailscale }),
           !selected.contains(where: { $0.endpoint == legacyTailscale.endpoint }) {
            selected.append(legacyTailscale)
        }
        return selected == local ? nil : selected
    }

    /// Whether a background registry refresh may write back into the paired-Mac
    /// store, re-evaluated *after* the network call.
    ///
    /// The refresh upserts with `markActive: true`, so it must not resurrect a
    /// pairing the user removed or deactivated while the network call was in
    /// flight. It is safe to apply only when the same user is still signed in and
    /// the Mac it refreshed is still the active paired Mac. If the user signed
    /// out, switched accounts, forgot the Mac, or switched to a different active
    /// Mac, the captured user no longer matches, or the active Mac id is now
    /// `nil`/different, so the write is rejected.
    public static func shouldApplyRegistryRefresh(
        isSignedIn: Bool,
        capturedUserID: String?,
        currentUserID: String?,
        activeMacID: String?,
        activeMacInstanceTag: String? = nil,
        targetMacID: String,
        targetInstanceTag: String? = nil
    ) -> Bool {
        guard isSignedIn else { return false }
        guard capturedUserID == currentUserID else { return false }
        return activeMacID == targetMacID && activeMacInstanceTag == targetInstanceTag
    }

    // MARK: - DeviceRegistryRefreshing

    public func freshRoutes(
        forMacDeviceID macDeviceID: String,
        instanceTag: String?
    ) async -> [CmxAttachRoute]? {
        guard let response = await fetchListResponse(),
              (200...299).contains(response.statusCode) else { return nil }
        return Self.routes(
            forMacDeviceID: macDeviceID,
            pairedMacInstanceTag: instanceTag,
            in: response.data
        )
    }

    public func listDevices() async -> DeviceRegistryListOutcome {
        // No request could be built (no valid session/tokens): treat as a
        // transient failure rather than an auth rejection, since this is the
        // signed-out / not-yet-bootstrapped case, not the registry actively
        // rejecting the caller's scope.
        guard let response = await fetchListResponse() else {
            return .transientFailure
        }
        // An auth/scope rejection (401/403) must clear the cached team-scoped
        // data; any other non-2xx (5xx, etc.) is transient and keeps it.
        if response.statusCode == 401 || response.statusCode == 403 {
            return .authRejected
        }
        guard (200...299).contains(response.statusCode) else {
            return .transientFailure
        }
        // A 2xx with an undecodable body is a server/contract glitch, not an auth
        // rejection: keep the current tree rather than blanking it.
        guard let devices = Self.parseDeviceList(in: response.data) else {
            return .transientFailure
        }
        return .ok(devices)
    }

    /// Share one in-flight `/api/devices` read across the device tree and the
    /// reconnect route refresher when both callers have the exact same auth and
    /// team scope. This removes duplicate provider work without returning an old
    /// account or team's response after a session switch.
    private func fetchListResponse() async -> RegistryResponse? {
        guard let input = await makeListRequest() else { return nil }
        if let inFlight = listResponseTasks[input.scope] {
            return await inFlight.task.value
        }
        let id = UUID()
        let task = Task { [self] in
            await performListResponseRequest(input.request)
        }
        listResponseTasks[input.scope] = InFlightRegistryRequest(id: id, task: task)
        let response = await task.value
        if listResponseTasks[input.scope]?.id == id {
            listResponseTasks[input.scope] = nil
        }
        return response
    }

    private func performListResponseRequest(_ request: URLRequest) async -> RegistryResponse? {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return nil
            }
            return RegistryResponse(data: data, statusCode: http.statusCode)
        } catch {
            deviceRegistryLog.debug("registry list request failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    // MARK: - Parsing (pure, testable)

    /// Decode the `/api/devices` list response into the full two-level device
    /// tree (devices → app instances), for the device tree UI. Returns `nil` only
    /// when the top-level envelope is undecodable; individual bad routes are
    /// dropped (not fatal) so one malformed sibling can't blank the whole tree.
    ///
    /// Each route is decoded *failably* and individually (same forward-compat
    /// contract as ``routes(forMacDeviceID:in:)``): a malformed or unknown-kind
    /// route is skipped rather than failing its instance, so an old client stays
    /// forward-compatible when a newer build advertises a route kind it cannot
    /// decode. `lastSeenAt` is parsed leniently (ISO8601, with or without
    /// fractional seconds), defaulting to ``Date/distantPast`` when absent so a
    /// device still renders, just sorted oldest.
    static func parseDeviceList(in data: Data) -> [RegistryDevice]? {
        struct FailableRoute: Decodable {
            let value: CmxAttachRoute?
            init(from decoder: Decoder) throws {
                value = try? CmxAttachRoute(from: decoder)
            }
        }
        struct FailableLabel: Decodable {
            let value: String?
            init(from decoder: any Decoder) throws {
                value = try? decoder.singleValueContainer().decode(String.self)
            }
        }
        struct Instance: Decodable {
            let tag: String?
            let routes: [FailableRoute]?
            let lastSeenAt: String?
            let labels: [String: FailableLabel]?
        }
        struct Device: Decodable {
            let deviceId: String
            let platform: String?
            let displayName: String?
            let lastSeenAt: String?
            let isOwnedByCurrentUser: Bool?
            let instances: [Instance]?
        }
        struct ListResponse: Decodable {
            let devices: [Device]
        }
        guard let decoded = try? JSONDecoder().decode(ListResponse.self, from: data) else {
            return nil
        }
        return decoded.devices.compactMap { device -> RegistryDevice? in
            let deviceId = device.deviceId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !deviceId.isEmpty else { return nil }
            let instances = (device.instances ?? []).map { instance in
                let tag = instance.tag?.trimmingCharacters(in: .whitespacesAndNewlines)
                return RegistryAppInstance(
                    tag: tag?.isEmpty == false ? tag! : "default",
                    routes: (instance.routes ?? []).compactMap(\.value),
                    lastSeenAt: Self.parseTimestamp(instance.lastSeenAt),
                    labels: (instance.labels ?? [:]).compactMapValues(\.value)
                )
            }
            return RegistryDevice(
                deviceId: deviceId,
                platform: device.platform?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                    ? device.platform! : "mac",
                displayName: device.displayName,
                lastSeenAt: Self.parseTimestamp(device.lastSeenAt),
                instances: instances,
                isOwnedByCurrentUser: device.isOwnedByCurrentUser ?? false
            )
        }
    }

    /// Lenient ISO8601 parse for the registry's `lastSeenAt` strings. The server
    /// emits `Date.toISOString()` (always fractional seconds), but tolerate the
    /// non-fractional form too. An absent/unparseable value yields
    /// ``Date/distantPast`` so the device still renders rather than being dropped.
    ///
    /// The formatters are created per call rather than cached in a `static` so
    /// this stays `Sendable`-clean under strict concurrency (`ISO8601DateFormatter`
    /// is not `Sendable`). This runs once per `/api/devices` response, not on any
    /// hot path, so the allocation is negligible.
    static func parseTimestamp(_ value: String?) -> Date {
        guard let value, !value.isEmpty else { return .distantPast }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: value) { return date }
        if let date = ISO8601DateFormatter().date(from: value) { return date }
        return .distantPast
    }

    /// Return authoritative routes for a matching device from one decoded
    /// registry snapshot. A scoped client selects its exact Mac app-instance
    /// tag; an unscoped client accepts routes only when exactly one instance on
    /// that physical device advertises any. Returns `nil` when ownership cannot
    /// be proven.
    static func routes(
        forMacDeviceID macDeviceID: String,
        pairedMacInstanceTag: String? = nil,
        in devices: [RegistryDevice]
    ) -> [CmxAttachRoute]? {
        guard case .unique(let routes) = DeviceRegistryRouteIndex(devices: devices).resolve(
            macDeviceID: macDeviceID,
            instanceTag: pairedMacInstanceTag
        ) else { return nil }
        return routes
    }

    /// Decode the `/api/devices` list response and return authoritative routes
    /// for the matching device. Each route is decoded *failably* and
    /// individually by ``parseDeviceList(in:)``: a malformed or unknown-kind
    /// route from any instance is skipped rather than failing the whole response.
    /// This keeps one bad sibling row from disabling registry refresh for every
    /// Mac and makes old clients forward-compatible with new route kinds.
    static func routes(
        forMacDeviceID macDeviceID: String,
        pairedMacInstanceTag: String? = nil,
        in data: Data
    ) -> [CmxAttachRoute]? {
        guard let devices = parseDeviceList(in: data) else { return nil }
        return routes(
            forMacDeviceID: macDeviceID,
            pairedMacInstanceTag: pairedMacInstanceTag,
            in: devices
        )
    }

    // MARK: - Request building

    private func makeListRequest() async -> RegistryListRequest? {
        guard let accessToken = await tokenSource.accessToken(),
              let refreshToken = await tokenSource.refreshToken(),
              let url = URL(string: apiBaseURL + "/api/devices") else {
            return nil
        }
        let providedTeamID = await teamIDProvider()
        let teamID = providedTeamID?.isEmpty == false ? providedTeamID : nil
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = requestTimeout
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(refreshToken, forHTTPHeaderField: "X-Stack-Refresh-Token")
        if let teamID {
            request.setValue(teamID, forHTTPHeaderField: "X-Cmux-Team-Id")
        }
        return RegistryListRequest(
            request: request,
            scope: RegistryRequestScope(
                accessToken: accessToken,
                refreshToken: refreshToken,
                teamID: teamID
            )
        )
    }
}

/// Provides Keychain-scoped device identities for one exact iOS app namespace.
public extension MobileIOSAppNamespace {
    /// Returns this app bundle's stable device-registry identity.
    ///
    /// The exact bundle namespace selects a device-only Keychain service. The
    /// best-effort registry read may return a process-stable ephemeral value
    /// when protected storage is unavailable, but that value is never used for
    /// an Iroh binding.
    ///
    /// - Parameters:
    ///   - keychainAccessGroup: This app's exact signed Keychain access group.
    ///   - defaults: Legacy mirror storage, injectable for tests.
    func deviceRegistryDeviceID(
        keychainAccessGroup: String?,
        defaults: UserDefaults = .standard,
        deviceWitness: String? = nil,
        evidence: any SameDeviceEvidenceProbing = IrohEndpointIdentityEvidenceProbe()
    ) -> String {
        DeviceRegistryService.deviceID(
            store: KeychainDeviceIdentityStore(
                service: keychainService(
                    base: "com.cmuxterm.deviceRegistry.iosDeviceID.v1"
                ),
                accessGroup: keychainAccessGroup,
                legacyService: "com.cmuxterm.deviceRegistry.iosDeviceID.v1"
            ),
            defaults: defaults,
            deviceWitness: deviceWitness,
            evidence: evidence
        )
    }

    /// Returns this app bundle's durable Iroh device identity.
    ///
    /// A `nil` result means protected storage is unavailable or a fresh value
    /// could not be persisted. Callers must defer broker registration instead
    /// of substituting an ephemeral identity.
    ///
    /// - Parameters:
    ///   - keychainAccessGroup: This app's exact signed Keychain access group.
    ///   - defaults: Legacy mirror storage, injectable for tests.
    func durableDeviceRegistryDeviceID(
        keychainAccessGroup: String?,
        defaults: UserDefaults = .standard,
        deviceWitness: String? = nil,
        evidence: any SameDeviceEvidenceProbing = IrohEndpointIdentityEvidenceProbe()
    ) -> String? {
        DeviceRegistryService.durableDeviceID(
            store: KeychainDeviceIdentityStore(
                service: keychainService(
                    base: "com.cmuxterm.deviceRegistry.iosDeviceID.v1"
                ),
                accessGroup: keychainAccessGroup,
                legacyService: "com.cmuxterm.deviceRegistry.iosDeviceID.v1"
            ),
            defaults: defaults,
            deviceWitness: deviceWitness,
            evidence: evidence
        )
    }
}

/// Exact, immutable authority lookup for one authenticated registry generation.
/// Building it once keeps a reconnect pass linear even with many saved Macs.
struct DeviceRegistryRouteIndex: Sendable {
    private let devicesByID: [String: [RegistryDevice]]
    private let macInstanceTagAuthority: MobileMacInstanceTagAuthority

    init(
        devices: [RegistryDevice],
        macInstanceTagAuthority: MobileMacInstanceTagAuthority =
            MobileMacInstanceTagAuthority()
    ) {
        self.macInstanceTagAuthority = macInstanceTagAuthority
        devicesByID = Dictionary(grouping: devices) { device in
            Self.normalizedDeviceID(device.deviceId)
        }
    }

    func resolve(
        macDeviceID: String,
        instanceTag: String?
    ) -> DeviceRegistryRouteResolution {
        let matches = devicesByID[Self.normalizedDeviceID(macDeviceID)] ?? []
        guard !matches.isEmpty else { return .missing }
        guard matches.count == 1, let device = matches.first else { return .ambiguous }

        let instances: [RegistryAppInstance]
        if let expectedTag = macInstanceTagAuthority.normalize(instanceTag) {
            instances = device.instances.filter {
                macInstanceTagAuthority.normalize($0.tag) == expectedTag
            }
        } else {
            instances = device.instances
        }
        let nonEmptyRoutes = instances.map(\.routes).filter { !$0.isEmpty }
        guard !nonEmptyRoutes.isEmpty else { return .missing }
        guard nonEmptyRoutes.count == 1 else { return .ambiguous }
        return .unique(nonEmptyRoutes[0])
    }

    private static func normalizedDeviceID(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

enum DeviceRegistryRouteResolution: Equatable, Sendable {
    case unique([CmxAttachRoute])
    case missing
    case ambiguous
}
