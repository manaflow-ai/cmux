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
    public func refreshCaffeineStatus() async -> Bool {
        guard supportsCaffeineControl, let client = remoteClient else {
            caffeineStatus = nil
            return false
        }
        let generation = connectionGeneration
        do {
            let data = try await client.sendRequest(
                MobileCoreRPCClient.requestData(
                    method: "caffeine.status",
                    params: [:]
                ),
                timeoutNanoseconds: Self.caffeineRequestTimeoutNanoseconds
            )
            let status = try MobileCaffeineStatus.decode(data)
            guard isCurrentRemoteOperation(
                client: client,
                generation: generation
            ) else { return false }
            caffeineStatus = status
            return true
        } catch {
            guard remoteClient === client,
                  connectionGeneration == generation else { return false }
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
        let previousStatus = caffeineStatus
        let mutationID = UUID()
        caffeineMutationID = mutationID
        isCaffeineMutationInFlight = true
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
            let status = try MobileCaffeineStatus.decode(data)
            guard isCurrentRemoteOperation(
                client: client,
                generation: generation
            ), caffeineMutationID == mutationID else { return false }
            caffeineStatus = status
            return true
        } catch {
            guard remoteClient === client,
                  connectionGeneration == generation,
                  caffeineMutationID == mutationID else { return false }
            caffeineStatus = previousStatus
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
            return false
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
              let status = try? MobileCaffeineStatus.decode(payload) else {
            return
        }
        caffeineStatus = status
    }
}
