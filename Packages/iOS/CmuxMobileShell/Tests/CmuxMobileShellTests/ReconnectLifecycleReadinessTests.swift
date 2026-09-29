import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
extension ReconnectRouteSelectionTests {
    @Test func blockedLifecycleParksReconnectWithoutDialOrBackoff() async throws {
        let readiness = TestMobileConnectionReadiness(permitsConnection: false)
        let router = LivenessHostRouter()
        let factory = KindRecordingTransportFactory(router: router, box: TransportBox())
        let runtime = LivenessTestRuntime(connectionReadiness: readiness,
                                         transportFactory: factory, now: Date.init, supportedRouteKinds: [.iroh])
        let shell = try await makeReconnectStore(routes: [try iroh()], runtime: runtime)
        let outcome = await shell.reconnectActiveMacOutcome(stackUserID: "user-1")
        if case .superseded = outcome {} else { Issue.record("Lifecycle deferral must be superseded") }
        #expect(factory.attemptedKinds().isEmpty)
        #expect(!shell.isReconnectingStoredMac)
        #expect(shell.pendingInactiveRecoveryTrigger != nil)
        #expect(shell.automaticReconnectBackoffOwner.transientRetryAt == nil)
        // Exercise the next admitted attempt before releasing any stale work.
        readiness.permitsConnection = true
        #expect(await shell.reconnectActiveMacIfAvailable(stackUserID: "user-1"))
        #expect(factory.attemptedKinds() == [.iroh])
        await shell.remoteClient?.disconnect()
    }

    @Test func backgroundLifecycleBlocksEvenAnExplicitStoredReconnect() async throws {
        let router = LivenessHostRouter()
        let factory = KindRecordingTransportFactory(router: router, box: TransportBox())
        let runtime = LivenessTestRuntime(transportFactory: factory, now: Date.init, supportedRouteKinds: [.iroh])
        let shell = try await makeReconnectStore(routes: [try iroh()], runtime: runtime)
        shell.suspendForegroundRefresh()
        let outcome = await shell.reconnectActiveMacOutcome(stackUserID: "user-1", force: true)
        if case .superseded = outcome {} else { Issue.record("A background reconnect must defer") }
        #expect(factory.attemptedKinds().isEmpty)
        #expect(!shell.isReconnectingStoredMac)
        #expect(shell.automaticReconnectBackoffOwner.transientRetryAt == nil)
    }
}
