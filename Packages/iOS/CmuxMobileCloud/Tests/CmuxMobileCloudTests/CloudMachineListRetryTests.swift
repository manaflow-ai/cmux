import Foundation
import Testing
@testable import CmuxMobileCloud

/// The machine list heals from transient failures on its own, and never
/// mistakes a transient session state for a sign-out.
@MainActor
@Suite struct CloudMachineListRetryTests {
    private static let machine = CloudMachine(id: "vm-1", provider: "freestyle", status: "running")

    private func makeController(service: FakeCloudVMService, clock: TestClock) -> CloudSessionController {
        CloudSessionController(
            service: service,
            identityStore: InMemoryCloudDeviceIdentityStore(),
            tunnelStarter: FakeTunnelStarter(),
            connector: FakeConnector(),
            stateDirectory: Fixtures.stateDirectory(),
            deviceName: "iPhone",
            approvalClock: clock
        )
    }

    private func settle(_ condition: @MainActor () -> Bool) async {
        for _ in 0 ..< 2_000 where !condition() {
            await Task.yield()
        }
    }

    @Test func aFirstTransientFailureRetriesQuietly() async {
        let service = FakeCloudVMService()
        service.machines = .failure(CloudAPIError.sessionUnavailable)
        let clock = TestClock()
        let controller = makeController(service: service, clock: clock)
        controller.sceneWillEnterForeground()

        controller.refreshMachines()
        await settle { clock.sleepers == 1 }
        // Still loading: the user sees a spinner, not an error.
        #expect(controller.machines.isLoading)

        service.machines = .success([Self.machine])
        clock.advance(by: .seconds(2))
        await settle { controller.machines == .loaded([Self.machine]) }
        #expect(controller.machines == .loaded([Self.machine]))
        #expect(service.calls.list == 2)
    }

    @Test func repeatedTransientFailuresShowAndKeepRetryingWithBackoff() async {
        let service = FakeCloudVMService()
        service.machines = .failure(CloudAPIError.httpStatus(503, message: "provider down", action: nil))
        let clock = TestClock()
        let controller = makeController(service: service, clock: clock)
        controller.sceneWillEnterForeground()

        controller.refreshMachines()
        await settle { clock.sleepers == 1 }
        clock.advance(by: .seconds(2))
        await settle { if case .failed = controller.machines { return clock.sleepers == 1 } else { return false } }
        guard case .failed(let failure, _) = controller.machines else {
            Issue.record("the second failure should be shown")
            return
        }
        #expect(failure.kind == .controlPlane(status: 503))
        #expect(service.calls.list == 2)

        // The next read waits five seconds.
        clock.advance(by: .seconds(4))
        for _ in 0 ..< 200 { await Task.yield() }
        #expect(service.calls.list == 2)
        service.machines = .success([Self.machine])
        clock.advance(by: .seconds(1))
        await settle { controller.machines == .loaded([Self.machine]) }
        #expect(service.calls.list == 3)
    }

    @Test func aSignOutIsShownAndNotRetried() async {
        let service = FakeCloudVMService()
        service.machines = .failure(CloudAPIError.notSignedIn)
        let clock = TestClock()
        let controller = makeController(service: service, clock: clock)
        controller.sceneWillEnterForeground()

        controller.refreshMachines()
        await settle { if case .failed = controller.machines { return true } else { return false } }
        guard case .failed(let failure, _) = controller.machines else {
            Issue.record("a sign-out should be shown immediately")
            return
        }
        #expect(failure.kind == .signedOut)
        for _ in 0 ..< 200 { await Task.yield() }
        #expect(clock.sleepers == 0)
    }

    @Test func aRefusedRequestIsNotRetried() async {
        let service = FakeCloudVMService()
        service.machines = .failure(CloudAPIError.httpStatus(403, message: "forbidden", action: nil))
        let clock = TestClock()
        let controller = makeController(service: service, clock: clock)
        controller.sceneWillEnterForeground()

        controller.refreshMachines()
        await settle { if case .failed = controller.machines { return true } else { return false } }
        for _ in 0 ..< 200 { await Task.yield() }
        #expect(clock.sleepers == 0)
    }

    @Test func aThrowingTokenReadIsTransientButANilPairIsASignOut() async throws {
        func service(_ pair: @escaping @Sendable () async throws -> CloudAPITokenSource.TokenPair?) -> CloudVMService {
            CloudVMService(
                baseURL: "https://cmux.invalid",
                tokens: CloudAPITokenSource(
                    accessToken: { nil },
                    refreshToken: { nil },
                    coherentTokenPair: pair
                ),
                deviceID: { "device" }
            )
        }
        struct RefreshInFlight: Error {}
        await #expect(throws: CloudAPIError.sessionUnavailable) {
            _ = try await service({ throw RefreshInFlight() }).listMachines()
        }
        await #expect(throws: CloudAPIError.notSignedIn) {
            _ = try await service({ nil }).listMachines()
        }
        #expect(CloudSessionFailure.classify(CloudAPIError.sessionUnavailable, stage: .list).isRetryable)
        #expect(!CloudSessionFailure.classify(CloudAPIError.notSignedIn, stage: .list).isRetryable)
    }

    @Test func listRetryDelays() {
        let delays = (1...7).map { CloudSessionController.listRetryDelay(afterFailures: $0) }
        #expect(delays == [.seconds(2), .seconds(5), .seconds(10), .seconds(20), .seconds(40), .seconds(60), .seconds(60)])
    }

    @Test func namesPreferLabelThenGeneratedNameThenShortID() {
        #expect(CloudMachine(id: "vm-47d043680f5640e0a6b812d34e309afb", provider: "freestyle", status: "running", slug: "whimsical-cobalt-butterfly").preferredName == "whimsical-cobalt-butterfly")
        #expect(CloudMachine(id: "vm-47d043680f5640e0a6b812d34e309afb", provider: "freestyle", status: "running", displayName: "api box", slug: "whimsical-cobalt-butterfly").preferredName == "api box")
        #expect(CloudMachine(id: "vm-47d043680f5640e0a6b812d34e309afb", provider: "freestyle", status: "running").preferredName == "vm-47d04368")
    }

    @Test func machineListDecodesTheGeneratedName() throws {
        let json = #"{"vms":[{"id":"vm-1","provider":"freestyle","status":"running","displayName":null,"slug":"clever-aqua-grouse"}]}"#
        let catalog = try CloudAPIResponseDecoding().catalog(from: Data(json.utf8))
        #expect(catalog.machines.first?.slug == "clever-aqua-grouse")
        #expect(catalog.machines.first?.preferredName == "clever-aqua-grouse")
    }

    @Test func terminalNamesFallBackToTitleThenDirectory() {
        #expect(CloudTerminalSummary(id: "term_1", name: "build").displayName == "build")
        #expect(CloudTerminalSummary(id: "term_1", title: "aziz@vm: ~/api").displayName == "aziz@vm: ~/api")
        #expect(CloudTerminalSummary(id: "term_1", title: "  ", currentDirectory: "/home/user/api").displayName == "~/api")
        #expect(CloudTerminalSummary(id: "term_1").displayName == "term_1")
    }
}
