internal import CMUXMobileCore
internal import CmuxMobileShellModel
internal import CmuxMobileSupport
internal import CmuxMobileTransport
import Foundation

/// The connection doctor's decision-tree checklist: one verdict per
/// ``ConnectionDoctorItem/CheckID``, in fixed tree order
/// (network -> tailnet -> account -> Mac app -> listener -> routes), built as
/// a pure function of ``ConnectionDoctorProbeResults``.
///
/// Probes run concurrently, so when one misconfiguration causes several checks
/// to fail (no network also makes the Mac unreachable), every observation is
/// reported honestly and ``primaryFailure`` (the first failing row in tree
/// order) names the misconfiguration to fix first.
public struct ConnectionDoctorReport: Equatable, Sendable {
    /// One item per check, in ``ConnectionDoctorItem/CheckID/allCases`` order.
    public let items: [ConnectionDoctorItem]

    /// The first failing item in decision-tree order: the root-cause row the
    /// UI marks "Start here". `nil` when nothing failed.
    public var primaryFailure: ConnectionDoctorItem? {
        items.first(where: \.isFailure)
    }

    /// Builds the checklist from one set of probe observations.
    /// - Parameter results: The injected probe results.
    /// - Returns: A report with exactly one item per check, in tree order.
    public static func make(results: ConnectionDoctorProbeResults) -> ConnectionDoctorReport {
        ConnectionDoctorReport(items: ConnectionDoctorItem.CheckID.allCases.map { id in
            ConnectionDoctorItem(id: id, status: status(of: id, results: results))
        })
    }

    /// Creates a report from already-built items (tests and previews).
    /// - Parameter items: The checklist rows.
    public init(items: [ConnectionDoctorItem]) {
        self.items = items
    }

    // MARK: - Per-check verdicts (pure)

    private static func status(
        of id: ConnectionDoctorItem.CheckID,
        results: ConnectionDoctorProbeResults
    ) -> ConnectionDoctorItem.Status {
        switch id {
        case .network: return networkStatus(results)
        case .localNetwork: return localNetworkStatus(results)
        case .tailnetPhone: return tailnetPhoneStatus(results)
        case .macReachable: return macReachableStatus(results)
        case .account: return accountStatus(results)
        case .listener: return listenerStatus(results)
        case .routes: return routesStatus(results)
        case .ticket: return ticketStatus(results)
        }
    }

    private static func networkStatus(_ results: ConnectionDoctorProbeResults) -> ConnectionDoctorItem.Status {
        switch results.isOnline {
        case true?:
            return .pass(detail: nil)
        case false?:
            return .fail(fix: L10n.string(
                "mobile.doctor.fix.offline",
                defaultValue: "This device is offline. Connect to Wi-Fi or cellular, then run the checkup again."
            ))
        case nil:
            return .unknown(note: nil)
        }
    }

    private static func localNetworkStatus(_ results: ConnectionDoctorProbeResults) -> ConnectionDoctorItem.Status {
        let blocked = results.dials.contains { $0.outcome == .permissionDenied }
            || results.snapshot.lastPairingFailure == .localNetworkBlocked
        if blocked {
            return .fail(fix: L10n.string(
                "mobile.doctor.fix.localNetwork",
                defaultValue: "iOS is blocking the connection. Allow cmux to use the Local Network in iOS Settings, then run the checkup again."
            ))
        }
        guard !results.dials.isEmpty else {
            return .unknown(note: L10n.string(
                "mobile.doctor.note.noDial",
                defaultValue: "No saved address to dial yet."
            ))
        }
        return .pass(detail: nil)
    }

    private static func tailnetPhoneStatus(_ results: ConnectionDoctorProbeResults) -> ConnectionDoctorItem.Status {
        let routes = results.snapshot.routes
        if !routes.isEmpty, !routes.contains(where: MobileShellRouteAuthPolicy.routeRequiresTailnet) {
            return .skipped(note: L10n.string(
                "mobile.doctor.note.notTailnetRoute",
                defaultValue: "The saved address doesn't use Tailscale."
            ))
        }
        switch results.tailscale {
        case .active:
            return .pass(detail: nil)
        case .inactiveOrNotInstalled:
            return .fail(fix: L10n.string(
                "mobile.doctor.fix.tailscaleOff",
                defaultValue: "Tailscale is off on this device (or not installed). Open the Tailscale app, turn it on, then run the checkup again."
            ))
        case .unknown, nil:
            return .unknown(note: nil)
        }
    }

    private static func macReachableStatus(_ results: ConnectionDoctorProbeResults) -> ConnectionDoctorItem.Status {
        guard !results.dials.isEmpty else {
            return undialableStatus(results)
        }
        if let reached = results.dials.first(where: { $0.outcome == .accepted || $0.outcome == .refused }) {
            return .pass(detail: hostPortDetail(of: reached.route))
        }
        // Routes are priority-ordered; the first dial's failure names the message.
        switch results.dials[0].outcome {
        case .dnsFailed:
            return .fail(fix: L10n.string(
                "mobile.doctor.fix.macDNS",
                defaultValue: "Couldn't resolve the Mac's address. Check that Tailscale is connected on both devices."
            ))
        case .timedOut:
            return .fail(fix: L10n.string(
                "mobile.doctor.fix.macTimeout",
                defaultValue: "The Mac didn't answer. It may be asleep: wake it and keep Tailscale connected on it."
            ))
        case .unreachable:
            return .fail(fix: L10n.string(
                "mobile.doctor.fix.macUnreachable",
                defaultValue: "The Mac isn't reachable at its saved address. Turn Tailscale on for the Mac and make sure both devices are on the same tailnet."
            ))
        case .permissionDenied:
            // The Local Network row above is the actionable one; report the
            // observation here without repeating its fix.
            return .unknown(note: L10n.string(
                "mobile.doctor.note.blockedDial",
                defaultValue: "The dial was blocked before reaching the network."
            ))
        case .failed, .accepted, .refused:
            return .fail(fix: L10n.string(
                "mobile.doctor.fix.macDialFailed",
                defaultValue: "Couldn't reach the Mac at its saved address. Check the Mac's network, then run the checkup again."
            ))
        }
    }

    private static func accountStatus(_ results: ConnectionDoctorProbeResults) -> ConnectionDoctorItem.Status {
        guard results.snapshot.isSignedIn else {
            return .fail(fix: L10n.string(
                "mobile.doctor.fix.notSignedIn",
                defaultValue: "Not signed in on this device. Sign in to cmux, then run the checkup again."
            ))
        }
        switch results.snapshot.lastPairingFailure {
        case .accountMismatch:
            return .fail(fix: L10n.string(
                "mobile.doctor.fix.accountMismatch",
                defaultValue: "This Mac is signed in to a different cmux account. Use the same account on both devices."
            ))
        case .authFailed:
            return .fail(fix: L10n.string(
                "mobile.doctor.fix.authFailed",
                defaultValue: "The Mac couldn't verify this account. Sign out and back in on both devices, then pair again."
            ))
        default:
            let detail = results.snapshot.accountEmail.map { email in
                String(format: L10n.string(
                    "mobile.addDevice.signedInFormat",
                    defaultValue: "Signed in as %@"
                ), email)
            }
            return .pass(detail: detail)
        }
    }

    private static func listenerStatus(_ results: ConnectionDoctorProbeResults) -> ConnectionDoctorItem.Status {
        guard !results.dials.isEmpty else {
            return undialableStatus(results)
        }
        if results.dials.contains(where: { $0.outcome == .accepted }) {
            return .pass(detail: nil)
        }
        if results.dials.contains(where: { $0.outcome == .refused }) {
            return .fail(fix: L10n.string(
                "mobile.doctor.fix.listenerOff",
                defaultValue: "The Mac is reachable, but cmux isn't running there (or iPhone connections are off). Open cmux on the Mac."
            ))
        }
        return .unknown(note: L10n.string(
            "mobile.doctor.note.needsReachableMac",
            defaultValue: "Can't check until the Mac is reachable."
        ))
    }

    private static func routesStatus(_ results: ConnectionDoctorProbeResults) -> ConnectionDoctorItem.Status {
        guard !results.snapshot.routes.isEmpty else {
            return .fail(fix: L10n.string(
                "mobile.doctor.fix.noRoutes",
                defaultValue: "No Mac is paired on this device. Pair with a QR or link from the Mac."
            ))
        }
        switch results.registry {
        case .differsFromStored:
            return .fail(fix: L10n.string(
                "mobile.doctor.fix.staleRoutes",
                defaultValue: "The Mac's address changed since pairing. Reconnect to refresh it, or pair again from the Mac."
            ))
        case .matchesStored, .unavailable, .notAttempted:
            return .pass(detail: nil)
        }
    }

    private static func ticketStatus(_ results: ConnectionDoctorProbeResults) -> ConnectionDoctorItem.Status {
        if results.snapshot.lastPairingFailure == .ticketExpired {
            return .fail(fix: L10n.string(
                "mobile.doctor.fix.ticketExpired",
                defaultValue: "The pairing QR/link expired. Open pairing on the Mac and scan a fresh one."
            ))
        }
        if results.snapshot.hasActiveUnexpiredTicket {
            return .pass(detail: nil)
        }
        return .skipped(note: L10n.string(
            "mobile.doctor.note.pairingOnly",
            defaultValue: "Only checked while pairing."
        ))
    }

    // MARK: - Shared fragments

    /// The status for dial-based checks when there was nothing to dial: a
    /// no-paired-Mac setup skips (the routes row carries the fix), while
    /// saved-but-undialable routes (no host/port endpoint) are honestly unknown.
    private static func undialableStatus(_ results: ConnectionDoctorProbeResults) -> ConnectionDoctorItem.Status {
        guard !results.snapshot.routes.isEmpty else {
            return .skipped(note: L10n.string(
                "mobile.doctor.note.noPairedMac",
                defaultValue: "Nothing to check yet. Pair from the Mac first."
            ))
        }
        return .unknown(note: L10n.string(
            "mobile.doctor.note.undialable",
            defaultValue: "The saved route can't be checked with a direct dial."
        ))
    }

    private static func hostPortDetail(of route: CmxAttachRoute) -> String? {
        guard case let .hostPort(host, port) = route.endpoint else {
            return nil
        }
        return String(format: L10n.string(
            "mobile.doctor.detail.reachedFormat",
            defaultValue: "Reached %@:%d."
        ), host, port)
    }
}
