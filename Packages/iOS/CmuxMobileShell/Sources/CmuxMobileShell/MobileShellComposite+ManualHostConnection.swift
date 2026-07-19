import CMUXMobileCore
import CmuxMobileRPC
import CmuxMobileShellModel
import CmuxMobileSupport
import Foundation
import OSLog

private let mobileShellManualHostConnectionLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.cmux.ios",
    category: "mobile-shell"
)

@MainActor
extension MobileShellComposite {
    /// Connects to one explicit host while preserving the current foreground
    /// connection until trust and ownership validation have completed.
    ///
    /// - Parameter pairedMacDeviceID: The real paired-Mac device ID when the caller
    ///   knows it. A manual host whose Mac lacks `mobile.attach_ticket.create`
    ///   connects through a synthetic ticket; passing the real ID keeps aggregate
    ///   state keyed to the paired Mac. Pass `nil` for an unknown manual host.
    @discardableResult
    func connectManualHost(
        name: String,
        host: String,
        port: Int,
        pairedMacDeviceID: String? = nil,
        instanceTagExpectation: MobileMacInstanceTagExpectation = .adopt,
        recordsPairingAttempt: Bool,
        route: CmxAttachRoute? = nil,
        pendingMacSwitchAttemptID: UUID? = nil,
        ifStillCurrent: (() -> Bool)? = nil
    ) async -> MobilePairingURLConnectionResult {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let preservesActiveConnection = hasActiveMacConnection
        let authContext = currentRPCAuthContext()
        guard let normalizedHost = MobileShellRouteAuthPolicy().normalizedManualRouteHost(host) else {
            connectionError = L10n.string("mobile.addDevice.invalidHost", defaultValue: "Enter a host or IP address, without spaces or URL paths.")
            connectionErrorGuidance = nil
            clearFailedPairingConnection(preservingActiveConnection: preservesActiveConnection)
            analytics.capture("ios_pairing_failed", [
                "method": .string("manual"),
                "reason": .string("invalid_host"),
                "failure_phase": .string("validation"),
                "is_first_pair": .bool(!hasKnownPairedMac),
            ])
            return .failed
        }
        guard (1...65535).contains(port) else {
            connectionError = L10n.string("mobile.addDevice.invalidPort", defaultValue: "Enter a port from 1 to 65535.")
            connectionErrorGuidance = nil
            clearFailedPairingConnection(preservingActiveConnection: preservesActiveConnection)
            analytics.capture("ios_pairing_failed", [
                "method": .string("manual"),
                "reason": .string("invalid_port"),
                "failure_phase": .string("validation"),
                "is_first_pair": .bool(!hasKnownPairedMac),
            ])
            return .failed
        }

        guard authContext.hasStackUserID else {
            applyAuthorizationFailure(.authFailed, preservingActiveConnection: preservesActiveConnection)
            return .failed
        }
        let directRoute = try? routeSelection.manualHostRoute(host: normalizedHost, port: port, preserving: route)
        let approvalAttemptID = beginPairingValidationAttempt()
        if let directRoute {
            let needsApproval = await manualHostRouteNeedsApproval(
                directRoute,
                stackUserID: authContext.stackUserID
            )
            guard isCurrentPairingAttempt(approvalAttemptID),
                  isRPCAuthContextCurrent(authContext) else { return .superseded }
            if needsApproval {
                queueManualHostTrustWarning(
                    route: directRoute,
                    displayHost: normalizedHost,
                    pending: .manual(
                        attemptID: approvalAttemptID,
                        name: name,
                        host: normalizedHost,
                        port: port,
                        route: directRoute,
                        pairedMacDeviceID: pairedMacDeviceID,
                        instanceTagExpectation: instanceTagExpectation,
                        recordsPairingAttempt: recordsPairingAttempt,
                        macSwitchAttemptID: pendingMacSwitchAttemptID,
                        ifStillCurrent: ifStillCurrent
                    )
                )
                return .needsUserApproval
            }
        }
        let attemptID = recordsPairingAttempt
            ? beginPairingAttempt(method: "manual")
            : approvalAttemptID
        guard isCurrentPairingAttempt(attemptID) else { return .superseded }
        if !preservesActiveConnection {
            activeRoute = directRoute
        }
        switch await failPairingIfOffline(
            attemptID: attemptID,
            phase: "preflight",
            routes: directRoute.map { [$0] } ?? [],
            preservesActiveConnection: preservesActiveConnection
        ) {
        case .failedOffline: return .failed
        case .superseded: return .superseded
        case .proceed: break
        }
        do {
            guard ifStillCurrent?() != false else { return .superseded }
            let manualHostTrusted = await manualHostStackAuthTrusted(
                for: directRoute,
                stackUserID: authContext.stackUserID
            )
            guard isCurrentPairingAttempt(attemptID),
                  isRPCAuthContextCurrent(authContext),
                  ifStillCurrent?() != false else { return .superseded }
            let ticket = try await manualHostTicket(
                name: trimmedName,
                host: normalizedHost,
                port: port,
                route: directRoute,
                attemptStartedAt: pairingAttemptStartedAt,
                manualHostTrusted: manualHostTrusted,
                authContext: authContext
            )
            guard isCurrentPairingAttempt(attemptID) else { return .superseded }
            let noThrowFailure = try await connect(
                ticket: ticket,
                authContext: authContext,
                allowsStackAuthFallback: directRoute.map {
                    MobileShellRouteAuthPolicy().routeAllowsStackAuth(
                        $0,
                        manualHostTrusted: manualHostTrusted
                    )
                },
                pairedMacDeviceID: pairedMacDeviceID,
                instanceTagExpectation: instanceTagExpectation,
                ifStillCurrent: {
                    self.isCurrentPairingAttempt(attemptID)
                        && (ifStillCurrent?() ?? true)
                }
            )
            guard isCurrentPairingAttempt(attemptID) else { return .superseded }
            if noThrowFailure == nil, connectionState == .connected {
                recordPairingSucceeded()
                return .connected
            }
            recordFailureForCurrentConnectionError(phase: "connect", category: noThrowFailure)
            return .failed
        } catch is CancellationError {
            guard isCurrentPairingAttempt(attemptID) else { return .superseded }
            clearFailedPairingConnection(preservingActiveConnection: preservesActiveConnection)
            return .failed
        } catch {
            guard isCurrentPairingAttempt(attemptID) else { return .superseded }
            let routedError = error as? MobileShellRoutedConnectionError
            let underlyingError = routedError?.underlying ?? error
            let failureRoute = routedError?.route ?? directRoute ?? activeRoute
            mobileShellManualHostConnectionLog.error(
                "manual host pairing failed: \(String(describing: error), privacy: .private)"
            )
            if handleAuthorizationFailureIfNeeded(
                underlyingError,
                owner: .connectionAttempt(
                    route: failureRoute,
                    preservingActiveConnection: preservesActiveConnection
                )
            ) { return .failed }
            let category = MobilePairingFailureCategory.classify(error: underlyingError, route: failureRoute)
            applyPairingFailure(category, phase: "connect")
            clearFailedPairingConnection(preservingActiveConnection: preservesActiveConnection)
            return .failed
        }
    }
}
