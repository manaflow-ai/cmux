internal import CMUXMobileCore
internal import CmuxMobileRPC
internal import Foundation
internal import OSLog

nonisolated private let caffeineLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.cmux.ios",
    category: "mobile-caffeine"
)

extension MobileShellComposite {
    private static let caffeineRequestTimeoutNanoseconds: UInt64 = 5_000_000_000

    /// Reads the current Mac's authoritative cmux-owned keep-awake state.
    @discardableResult
    public func refreshCaffeineStatus(
        preservingRevision expectedRevision: UInt64? = nil
    ) async -> Bool {
        guard supportsCaffeineControl, let client = remoteClient else {
            caffeineStatus = nil
            return false
        }
        let generation = connectionGeneration
        let requestRevision = expectedRevision ?? caffeineStatusRevision
        guard expectedRevision == nil || caffeineStatusRevision == expectedRevision else {
            return false
        }
        do {
            let data = try await client.sendRequest(
                MobileCoreRPCClient.requestData(
                    method: "caffeine.status",
                    params: [:]
                ),
                timeoutNanoseconds: Self.caffeineRequestTimeoutNanoseconds
            )
            let status = try MobileCaffeineStatus(decoding: data)
            guard isCurrentRemoteOperation(
                client: client,
                generation: generation
            ) else { return false }
            guard caffeineStatusRevision == requestRevision else {
                return caffeineStatus != nil
            }
            caffeineStatus = status
            caffeineStatusRevision &+= 1
            return true
        } catch {
            guard remoteClient === client,
                  connectionGeneration == generation,
                  caffeineStatusRevision == requestRevision else { return false }
            caffeineStatus = nil
            guard !disconnectForAuthorizationFailureIfNeeded(error) else {
                return false
            }
            handleMacAvailabilityFailureIfCurrent(
                after: error,
                expectedClient: client,
                expectedGeneration: generation
            )
            caffeineLog.error(
                "caffeine.status failed error=\(String(describing: error), privacy: .public)"
            )
            return false
        }
    }

    /// Optimistically changes keep-awake, then replaces the optimistic value
    /// with the Mac's response or rolls it back on a current-connection error.
    @discardableResult
    public func setCaffeineEnabled(_ enabled: Bool) async -> Bool {
        guard supportsCaffeineControl,
              !isCaffeineMutationInFlight,
              let client = remoteClient else { return false }

        let generation = connectionGeneration
        let mutationID = UUID()
        caffeineMutationID = mutationID
        isCaffeineMutationInFlight = true
        caffeineStatusRevision &+= 1
        let requestRevision = caffeineStatusRevision
        caffeineStatus = MobileCaffeineStatus(enabled: enabled)
        defer {
            if caffeineMutationID == mutationID {
                caffeineMutationID = nil
                isCaffeineMutationInFlight = false
            }
        }

        do {
            let data = try await client.sendRequest(
                MobileCoreRPCClient.requestData(
                    method: "caffeine.set",
                    params: ["enabled": enabled]
                ),
                timeoutNanoseconds: Self.caffeineRequestTimeoutNanoseconds
            )
            let status = try MobileCaffeineStatus(decoding: data)
            guard isCurrentRemoteOperation(
                client: client,
                generation: generation
            ), caffeineMutationID == mutationID else { return false }
            guard caffeineStatusRevision == requestRevision else {
                return caffeineStatus?.enabled == enabled
            }
            caffeineStatus = status
            caffeineStatusRevision &+= 1
            return true
        } catch {
            guard remoteClient === client,
                  connectionGeneration == generation,
                  caffeineMutationID == mutationID else { return false }
            guard caffeineStatusRevision == requestRevision else {
                return caffeineStatus?.enabled == enabled
            }
            let statusRevision = caffeineStatusRevision
            // A timed-out or malformed response is ambiguous: caffeine.set may
            // have reached the Mac before the response was lost. Keep the UI in
            // an unknown state until a bounded status read confirms the result.
            caffeineStatus = nil
            guard !disconnectForAuthorizationFailureIfNeeded(error) else {
                return false
            }
            handleMacAvailabilityFailureIfCurrent(
                after: error,
                expectedClient: client,
                expectedGeneration: generation
            )
            caffeineLog.error(
                "caffeine.set failed error=\(String(describing: error), privacy: .public)"
            )
            _ = await refreshCaffeineStatus(
                preservingRevision: statusRevision
            )
            return caffeineStatus?.enabled == enabled
        }
    }

    func handleCaffeineStatusEvent(
        _ event: MobileEventEnvelope,
        client: MobileCoreRPCClient,
        generation: UUID
    ) {
        guard isCurrentRemoteOperation(client: client, generation: generation) else {
            return
        }
        guard let payload = event.payloadJSON,
              let status = try? MobileCaffeineStatus(decoding: payload) else {
            return
        }
        caffeineStatus = status
        caffeineStatusRevision &+= 1
    }
}
