import Foundation

/// What Cloud work this app may start on its own, decided from local state.
///
/// The Cloud subsystems that would otherwise start at launch ask here first:
/// the cmux-tui registry's fleet polling, and the app-managed tunnel (the
/// system Network Extension). A Mac that never turned on
/// `Settings › Beta Features › Cloud Machines` and never had a machine answers
/// "no" to all of it without a control-plane request and without touching
/// NetworkExtension. Nothing here probes NetworkExtension to decide whether
/// NetworkExtension may be used.
///
/// Two different facts are kept apart. "This Mac has used Cloud" (the cached
/// marker, or a tunnel role enrolled on this Mac) keeps an existing user's
/// fleet alive across an update. "The account has a machine right now" is
/// only ever the cached marker, which every fleet list refills, sign-out
/// clears, and a delete resets to unknown; launch-time decisions and status
/// treat anything but a known machine as "no", while an explicit Cloud use
/// (browser open, `cmux vpn up`) settles the count against the control plane
/// through `resolveCloudMachine` before a start is scheduled, whatever the
/// marker says: a machine deleted or created outside this app must not be
/// trusted or missed on the strength of the last poll.
///
/// The inputs are injected closures so the decision is testable without a
/// signed bundle; ``live(defaults:machineCache:browserTunnel:terminalTunnel:resolveCloudMachine:)``
/// wires the Beta Features toggle (plus the managed `DisableCloud` policy),
/// the cached machine count and this Mac's tunnel enrollment files, the
/// browser-role VPN configuration on disk, and ``VMClient`` for resolution.
struct CloudActivationPolicy: Sendable {
    /// `Settings › Beta Features › Cloud Machines` is on and no managed
    /// profile disables Cloud (``CloudMachinesFeature``).
    let isCloudMachinesEnabled: @Sendable () -> Bool
    /// This Mac has used Cloud before: the cached marker says the account had
    /// a machine, or a tunnel role was enrolled here (which only happens for a
    /// machine). Cleared by sign-out.
    let hasUsedCloud: @Sendable () -> Bool
    /// Whether the account owns at least one machine, as the cached marker
    /// last saw it (`true` or `false`); `nil` when nothing local can say
    /// (never listed, cleared by sign-out, or reset by a delete).
    let hasCloudMachine: @Sendable () -> Bool?
    /// The app-managed tunnel was configured on this Mac before (the
    /// browser-role WireGuard config exists), so a VPN configuration may be
    /// saved in NetworkExtension preferences.
    let isTunnelConfigured: @Sendable () -> Bool
    /// Asks the control plane whether the account has a machine; `nil` when it
    /// cannot answer (signed out, offline). Used only from an explicit Cloud
    /// use that is about to schedule a start, never at launch or for status.
    let resolveCloudMachine: @Sendable () async -> Bool?

    /// Fleet polling and links may run: the user opted in, or this Mac used
    /// Cloud before (an update must not strand a fleet the user already has).
    var allowsBackgroundCloudWork: Bool {
        isCloudMachinesEnabled() || hasUsedCloud()
    }

    /// The launch-time tunnel controller may read NetworkExtension preferences
    /// to adopt or stop a tunnel a previous app instance left running. False on
    /// every Mac that never saved a configuration, which is what keeps a fresh
    /// install and an update from 0.64.22 inert.
    var allowsLaunchTimeTunnelAdoption: Bool {
        isTunnelConfigured()
    }

    /// Why a tunnel start is refused as far as local state knows, or nil.
    /// Cloud Machines must be on; a machine count known to be zero refuses;
    /// an unknown count does not (``resolvedTunnelStartRefusal()`` settles it).
    func tunnelStartRefusal() -> CloudTunnelStartRefusal? {
        guard isCloudMachinesEnabled() else { return .cloudMachinesOff }
        return hasCloudMachine() == false ? .noCloudMachine : nil
    }

    /// ``tunnelStartRefusal()`` settled against the control plane: one fleet
    /// list decides, whatever the marker last said, so a machine deleted or
    /// created outside this app is neither trusted nor missed. An answer it
    /// cannot get (signed out, offline) keeps the local one: a marker that
    /// positively knows a machine admits, a marker that knows none refuses,
    /// and an unknown marker lets the start proceed so enrollment reports the
    /// real cause (sign in, network) before NetworkExtension is touched.
    func resolvedTunnelStartRefusal() async -> CloudTunnelStartRefusal? {
        guard isCloudMachinesEnabled() else { return .cloudMachinesOff }
        switch await resolveCloudMachine() {
        case .some(true):
            return nil
        case .some(false):
            return .noCloudMachine
        case nil:
            return hasCloudMachine() == false ? .noCloudMachine : nil
        }
    }

    /// Both answers, for ``CloudTunnelCoordinator``.
    var tunnelAdmission: CloudTunnelAdmission {
        CloudTunnelAdmission(
            knownRefusal: { tunnelStartRefusal() },
            resolvedRefusal: { await resolvedTunnelStartRefusal() }
        )
    }

    /// The production policy over this build's defaults, tunnel state files,
    /// and the signed-in ``VMClient``.
    static func live(
        defaults: UserDefaults = .standard,
        machineCache: CloudMachineCache = CloudMachineCache(),
        browserTunnel: VMTunnelManager = VMTunnelManager(purpose: .browser),
        terminalTunnel: VMTunnelManager = VMTunnelManager(purpose: .terminal),
        resolveCloudMachine: @escaping @Sendable () async -> Bool? = { await listedFleetHasMachine() }
    ) -> CloudActivationPolicy {
        // nonisolated(unsafe): UserDefaults is documented thread-safe but not
        // marked Sendable; the closure only reads through this handle.
        nonisolated(unsafe) let toggleDefaults = defaults
        return CloudActivationPolicy(
            isCloudMachinesEnabled: {
                CloudMachinesFeature.offMainIsEnabled(defaults: toggleDefaults)
            },
            hasUsedCloud: {
                machineCache.hasAnyMachine == true
                    || terminalTunnel.storedDeviceFingerprint() != nil
                    || browserTunnel.writtenConfig() != nil
            },
            hasCloudMachine: {
                machineCache.hasAnyMachine
            },
            isTunnelConfigured: {
                browserTunnel.writtenConfig() != nil
            },
            resolveCloudMachine: resolveCloudMachine
        )
    }

    /// One fleet list through the shared client; it refills
    /// ``CloudMachineCache`` as a side effect. `nil` when there is no client
    /// (not signed in) or the request fails.
    static func listedFleetHasMachine() async -> Bool? {
        let client: VMClient? = await MainActor.run { VMClient.shared }
        guard let client, let page = try? await client.listPage() else { return nil }
        return !page.vms.isEmpty
    }
}
