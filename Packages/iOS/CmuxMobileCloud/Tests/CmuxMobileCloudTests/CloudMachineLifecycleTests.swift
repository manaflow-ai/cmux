import Foundation
import Testing
@testable import CmuxMobileCloud

@MainActor
@Suite struct CloudMachineLifecycleTests {
    private static let running = CloudMachine(id: "vm-1", provider: "freestyle", status: "running", displayName: "otter")
    private static let paused = CloudMachine(id: "vm-1", provider: "freestyle", status: "paused", displayName: "otter")

    private func makeController(
        service: FakeCloudVMService,
        visibilityDefaults: UserDefaults = .standard
    ) -> CloudSessionController {
        CloudSessionController(
            service: service,
            identityStore: InMemoryCloudDeviceIdentityStore(),
            tunnelStarter: FakeTunnelStarter(),
            connector: FakeConnector(),
            stateDirectory: Fixtures.stateDirectory(),
            deviceName: "iPhone",
            visibilityDefaults: visibilityDefaults
        )
    }

    private func settle(_ condition: @MainActor () -> Bool) async {
        for _ in 0 ..< 2_000 where !condition() {
            await Task.yield()
        }
    }

    @Test func lifecycleMapsTheServerEnumAndGatesActions() {
        #expect(CloudMachineLifecycle(status: "running") == .running)
        #expect(CloudMachineLifecycle(status: "PAUSED") == .paused)
        #expect(CloudMachineLifecycle(status: "provisioning") == .provisioning)
        #expect(CloudMachineLifecycle(status: "failed") == .failed)
        #expect(CloudMachineLifecycle(status: "destroyed") == .destroyed)
        // A state the phone does not know yet must not hide the machine.
        #expect(CloudMachineLifecycle(status: "hibernating") == .unknown)

        #expect(CloudMachineLifecycle.running.canPause && !CloudMachineLifecycle.running.canResume)
        #expect(CloudMachineLifecycle.paused.canResume && !CloudMachineLifecycle.paused.canPause)
        #expect(!CloudMachineLifecycle.provisioning.canPause && !CloudMachineLifecycle.provisioning.canResume)
        #expect(CloudMachineLifecycle.failed.canDelete)
        #expect(!CloudMachineLifecycle.destroyed.canDelete)
        #expect(!CloudMachineLifecycle.unknown.canDelete)
    }

    @Test func requestsReachTheServersLifecycleRoutes() throws {
        let builder = CloudAPIRequestBuilder(baseURL: "https://cmux.com/")
        let pause = try builder.pauseMachine(id: "vm-1", accessToken: "a", refreshToken: "r")
        #expect(pause.httpMethod == "POST")
        #expect(pause.url?.absoluteString == "https://cmux.com/api/vm/vm-1/pause")

        let resume = try builder.resumeMachine(id: "vm-1", accessToken: "a", refreshToken: "r")
        #expect(resume.httpMethod == "POST")
        #expect(resume.url?.absoluteString == "https://cmux.com/api/vm/vm-1/resume")
        #expect(resume.timeoutInterval == CloudAPIRequestBuilder.resumeTimeout)

        let delete = try builder.deleteMachine(id: "vm-1", accessToken: "a", refreshToken: "r")
        #expect(delete.httpMethod == "DELETE")
        #expect(delete.url?.absoluteString == "https://cmux.com/api/vm/vm-1")

        // A machine id cannot change which route a request reaches: a slash
        // is encoded, so it stays one path segment.
        let hostile = try builder.deleteMachine(id: "vm-1/pause", accessToken: "a", refreshToken: "r")
        #expect(hostile.url?.absoluteString == "https://cmux.com/api/vm/vm-1%2Fpause")
        #expect(throws: CloudAPIError.self) {
            try builder.deleteMachine(id: "  ", accessToken: "a", refreshToken: "r")
        }
    }

    @Test func pauseCallsTheControlPlaneAndReconcilesFromTheList() async {
        let service = FakeCloudVMService()
        service.machines = .success([Self.paused])
        let controller = makeController(service: service)

        let ok = await controller.pauseMachine(Self.running)

        #expect(ok)
        #expect(service.calls.pause == ["vm-1"])
        #expect(controller.machineActionsInFlight.isEmpty)
        for _ in 0 ..< 500 where controller.machines.elements != [Self.paused] { await Task.yield() }
        #expect(controller.machines.elements == [Self.paused])
    }

    @Test func aFailedActionIsRecordedAgainstItsMachine() async {
        let service = FakeCloudVMService()
        service.lifecycleFailure = CloudAPIError.httpStatus(402, message: "vm_requires_pro", action: "Upgrade to Pro")
        let controller = makeController(service: service)

        let ok = await controller.resumeMachine(Self.paused)

        #expect(!ok)
        let failure = controller.lastMachineActionFailure
        #expect(failure?.machineID == "vm-1")
        #expect(failure?.action == .resume)
        #expect(failure?.failure.kind == .controlPlane(status: 402))
        #expect(failure?.failure.action == "Upgrade to Pro")
    }

    @Test func aSecondActionOnTheSameMachineIsRefusedWhileTheFirstRuns() async {
        let service = FakeCloudVMService()
        let controller = makeController(service: service)

        async let first = controller.deleteMachine(Self.running)
        async let second = controller.deleteMachine(Self.running)
        let results = await [first, second]

        // Exactly one delete reaches the server, however the two interleave.
        #expect(service.calls.delete == ["vm-1"])
        #expect(results.filter { $0 }.count == 1)
    }

    @Test func refreshRemovesConnectionsAndHiddenIDsForMissingMachines() async throws {
        let suite = "cmux-cloud-visibility-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["vm-1", "vm-deleted"], forKey: "mobile.cloud.hiddenMachineIDs.v2")

        let service = FakeCloudVMService()
        service.machines = .success([Self.running])
        let controller = makeController(service: service, visibilityDefaults: defaults)
        controller.sectionDidAppear()
        await settle {
            guard case .ready = controller.tunnel else { return false }
            return controller.machines.elements == [Self.running]
        }
        #expect(controller.hiddenMachineIDs == ["vm-1"])

        let oldConnection = try #require(controller.connection(for: Self.running))
        let replacement = CloudMachine(id: "vm-2", provider: "freestyle", status: "running")
        service.machines = .success([replacement])
        controller.refreshMachines()
        await settle { controller.machines.elements == [replacement] }

        #expect(controller.hiddenMachineIDs.isEmpty)
        let newConnection = try #require(controller.connection(for: Self.running))
        #expect(newConnection !== oldConnection)
        controller.sectionDidDisappear()
    }

    @Test func aProvisioningMachineIsReReadUntilItSettles() async {
        let service = FakeCloudVMService()
        let starting = CloudMachine(id: "vm-1", provider: "freestyle", status: "provisioning")
        let ready = CloudMachine(id: "vm-1", provider: "freestyle", status: "running")
        service.machines = .success([starting])
        let clock = TestClock()
        let controller = CloudSessionController(
            service: service,
            identityStore: InMemoryCloudDeviceIdentityStore(),
            tunnelStarter: FakeTunnelStarter(),
            connector: FakeConnector(),
            stateDirectory: Fixtures.stateDirectory(),
            deviceName: "iPhone",
            approvalClock: clock
        )

        controller.refreshMachines()
        for _ in 0 ..< 500 where clock.sleepers == 0 { await Task.yield() }
        #expect(service.calls.list == 1)
        #expect(clock.sleepers == 1)

        // The machine finishes booting server-side; the next tick picks it up
        // without the user pulling to refresh.
        service.machines = .success([ready])
        clock.advance(by: CloudSessionController.provisioningPollInterval)
        for _ in 0 ..< 500 where controller.machines.elements != [ready] { await Task.yield() }
        #expect(controller.machines.elements == [ready])
        #expect(service.calls.list == 2)

        // Settled: no further reads are scheduled.
        for _ in 0 ..< 50 { await Task.yield() }
        #expect(clock.sleepers == 0)
    }

    @Test func backgroundStopsTheProvisioningPoll() async {
        let service = FakeCloudVMService()
        service.machines = .success([CloudMachine(id: "vm-1", provider: "freestyle", status: "provisioning")])
        let clock = TestClock()
        let controller = CloudSessionController(
            service: service,
            identityStore: InMemoryCloudDeviceIdentityStore(),
            tunnelStarter: FakeTunnelStarter(),
            connector: FakeConnector(),
            stateDirectory: Fixtures.stateDirectory(),
            deviceName: "iPhone",
            approvalClock: clock
        )
        controller.refreshMachines()
        for _ in 0 ..< 500 where clock.sleepers == 0 { await Task.yield() }

        controller.sceneDidEnterBackground()
        clock.advance(by: CloudSessionController.provisioningPollInterval)
        for _ in 0 ..< 50 { await Task.yield() }

        #expect(service.calls.list == 1)
    }

    @Test func provisioningPollStopsWithRetryableFailureAfterItsBudget() async {
        let service = FakeCloudVMService()
        service.machines = .success([
            CloudMachine(id: "vm-1", provider: "freestyle", status: "provisioning")
        ])
        let clock = TestClock()
        let controller = CloudSessionController(
            service: service,
            identityStore: InMemoryCloudDeviceIdentityStore(),
            tunnelStarter: FakeTunnelStarter(),
            connector: FakeConnector(),
            stateDirectory: Fixtures.stateDirectory(),
            deviceName: "iPhone",
            approvalClock: clock,
            provisioningPollLimit: 2
        )

        controller.refreshMachines()
        await settle { clock.sleepers == 1 }
        clock.advance(by: CloudSessionController.provisioningPollInterval)
        await settle { service.calls.list >= 2 && clock.sleepers == 1 }
        clock.advance(by: CloudSessionController.provisioningPollInterval)
        await settle {
            if case .failed = controller.machines { return true }
            return false
        }

        guard case .failed(let failure, let previous) = controller.machines else {
            Issue.record("expected provisioning to stop with a failure")
            return
        }
        #expect(previous.count == 1)
        #expect(failure.kind == .other)
        #expect(failure.action == "Refresh to check again.")
        #expect(service.calls.list == 3)
        #expect(clock.sleepers == 0)
    }
}
