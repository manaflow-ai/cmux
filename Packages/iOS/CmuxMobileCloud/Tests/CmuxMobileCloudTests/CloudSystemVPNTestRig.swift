import Foundation
import Testing
@testable import CmuxMobileCloud

extension CloudSystemVPNTests {
    @MainActor
    struct Rig {
        let service = FakeCloudVMService()
        let store = InMemoryCloudDeviceIdentityStore()
        let manager = FakeSystemVPNManager()
        let pendingRevocationStore: any CloudSystemVPNPendingRevocationStoring
        let controller: CloudSystemVPNController

        init(
            operationTimeout: Duration = .seconds(30),
            cleanupRetryCount: Int = 3,
            pendingRevocationCapacity: Int = 4096,
            credentials: @escaping @Sendable () async -> CloudAPITokenSource.TokenContext? = {
                CloudAPITokenSource.TokenContext(
                    accessToken: "captured-access",
                    refreshToken: "captured-refresh"
                )
            },
            pendingRevocationStore: any CloudSystemVPNPendingRevocationStoring =
                InMemoryCloudSystemVPNPendingRevocationStore()
        ) {
            self.pendingRevocationStore = pendingRevocationStore
            controller = CloudSystemVPNController(
                service: service,
                identityStore: store,
                manager: manager,
                deviceName: "Aziz's iPhone",
                operationTimeout: operationTimeout,
                cleanupRetryCount: cleanupRetryCount,
                pendingRevocationCapacity: pendingRevocationCapacity,
                credentials: credentials,
                pendingRevocationStore: pendingRevocationStore
            )
        }

        func waitForPhase(_ expected: CloudSystemVPNPhase) async {
            while controller.phase != expected {
                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = controller.phase
                    } onChange: {
                        continuation.resume()
                    }
                }
            }
        }
    }
}
