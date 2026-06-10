internal import CMUXMobileCore
internal import CmuxMobilePairedMac
internal import CmuxMobileShellModel
internal import CmuxMobileTransport
import Foundation

/// Builds the connection doctor over the shell's injected seams (reachability,
/// the paired-Mac store, the device registry, identity, the system interface
/// walk, a raw TCP dial). Split out of `MobileShellComposite.swift` to keep
/// that file inside the Swift file length budget.
extension MobileShellComposite {
    /// Builds a connection doctor wired to this shell's live environment.
    /// One doctor per presentation of the checkup screen.
    /// - Parameter accountEmail: Supplies the signed-in account's email for
    ///   the checklist's account row (the shell only knows the user id).
    public func makeConnectionDoctor(
        accountEmail: @escaping @MainActor @Sendable () -> String? = { nil }
    ) -> ConnectionDoctor {
        ConnectionDoctor(
            probes: Self.connectionDoctorProbes(
                shell: self,
                reachability: reachability,
                pairedMacStore: pairedMacStore,
                deviceRegistry: deviceRegistry,
                identityProvider: identityProvider,
                accountEmail: accountEmail
            ),
            analytics: analytics
        )
    }

    private static func connectionDoctorProbes(
        shell: MobileShellComposite,
        reachability: any ReachabilityProviding,
        pairedMacStore: (any MobilePairedMacStoring)?,
        deviceRegistry: (any DeviceRegistryRefreshing)?,
        identityProvider: (any MobileIdentityProviding)?,
        accountEmail: @escaping @MainActor @Sendable () -> String?
    ) -> ConnectionDoctorProbes {
        ConnectionDoctorProbes(
            connection: { @MainActor [weak shell] in
                await Self.connectionDoctorSnapshot(
                    shell: shell,
                    pairedMacStore: pairedMacStore,
                    identityProvider: identityProvider,
                    accountEmail: accountEmail
                )
            },
            isOnline: {
                await reachability.isOnline
            },
            tailscale: {
                TailscaleStatus(
                    interfaces: SystemNetworkInterfaceAddressProvider().currentInterfaceAddresses()
                )
            },
            dial: { route in
                await ConnectionDoctorProbes.dialOverTCP(route)
            },
            registry: { @MainActor macDeviceID, stored in
                guard let deviceRegistry,
                      let macDeviceID,
                      !stored.isEmpty else {
                    return .notAttempted
                }
                guard let fresh = await deviceRegistry.freshRoutes(forMacDeviceID: macDeviceID),
                      !fresh.isEmpty else {
                    return .unavailable
                }
                // Same change-detection the reconnect path persists with, so the
                // doctor's "stale saved address" verdict matches what a reconnect
                // would actually rewrite.
                return DeviceRegistryService.selectReconnectRoutes(local: stored, registry: fresh) == nil
                    ? .matchesStored
                    : .differsFromStored
            }
        )
    }

    /// Captures the connection-relevant shell state the probes run against:
    /// the routes the next connect would dial (the active ticket's routes
    /// while one is held, else the stored active Mac's routes), the paired
    /// Mac's id, the account, and the last classified pairing failure.
    @MainActor
    private static func connectionDoctorSnapshot(
        shell: MobileShellComposite?,
        pairedMacStore: (any MobilePairedMacStoring)?,
        identityProvider: (any MobileIdentityProviding)?,
        accountEmail: @MainActor @Sendable () -> String?
    ) async -> ConnectionDoctorProbeResults.ConnectionSnapshot {
        guard let shell else {
            return ConnectionDoctorProbeResults.ConnectionSnapshot()
        }
        var routes = shell.activeTicket?.routes ?? []
        var macDeviceID = shell.activeTicket?.macDeviceID
        if routes.isEmpty, let pairedMacStore {
            let storedMac = try? await pairedMacStore.activeMac(
                stackUserID: identityProvider?.currentUserID
            )
            routes = storedMac?.routes ?? []
            macDeviceID = macDeviceID ?? storedMac?.macDeviceID
        }
        return ConnectionDoctorProbeResults.ConnectionSnapshot(
            routes: routes,
            macDeviceID: macDeviceID,
            isSignedIn: shell.isSignedIn,
            accountEmail: accountEmail(),
            lastPairingFailure: shell.lastPairingFailureCategory,
            hasActiveUnexpiredTicket: shell.hasActiveUnexpiredAttachTicket
        )
    }
}
