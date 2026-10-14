import Foundation
import Testing
@testable import CmuxMobileCloud

@MainActor
@Suite struct CloudMachineLifecycleTests {
    private static let running = CloudMachine(id: "vm-1", provider: "freestyle", status: "running", displayName: "otter")
    private static let paused = CloudMachine(id: "vm-1", provider: "freestyle", status: "paused", displayName: "otter")

    private func makeController(
        service: FakeCloudVMService,
        connector: FakeConnector = FakeConnector(),
        visibilityDefaults: UserDefaults = .standard,
        visibilityScope: String? = nil
    ) -> CloudSessionController {
        CloudSessionController(
            service: service,
            identityStore: InMemoryCloudDeviceIdentityStore(),
            tunnelStarter: FakeTunnelStarter(),
            connector: connector,
            stateDirectory: Fixtures.stateDirectory(),
            deviceName: "iPhone",
            visibilityDefaults: visibilityDefaults,
            visibilityScope: visibilityScope
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
        for invalidID in ["  ", ".", ".."] {
            #expect(throws: CloudAPIError.self) {
                try builder.deleteMachine(id: invalidID, accessToken: "a", refreshToken: "r")
            }
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

    @Test func lifecycleChangesCloseCachedConnectionBeforeReuse() async throws {
        let service = FakeCloudVMService()
        service.machines = .success([Self.running])
        let connector = FakeConnector()
        let controller = makeController(service: service, connector: connector)

        controller.sectionDidAppear()
        await settle {
            controller.machines.elements == [Self.running]
                && controller.tunnel == .ready(fingerprint: "ios-abc")
        }
        let runningConnection = try #require(controller.connection(for: Self.running))
        _ = try await runningConnection.loadCatalog()
        #expect(connector.connects.count == 1)

        service.machines = .success([Self.paused])
        controller.refreshMachines()
        await settle { controller.machines.elements == [Self.paused] }
        #expect(connector.session.state.disconnected == 1)

        service.machines = .success([Self.running])
        controller.refreshMachines()
        await settle { controller.machines.elements == [Self.running] }
        let resumedConnection = try #require(controller.connection(for: Self.running))
        #expect(resumedConnection !== runningConnection)
        _ = try await resumedConnection.loadCatalog()
        #expect(connector.connects.count == 2)

        controller.sectionDidDisappear()
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

    @Test func signOutCancelsAnInFlightLifecycleActionAndDropsItsLateResult() async {
        let service = FakeCloudVMService()
        service.holdLifecycleActions = true
        let controller = makeController(service: service)
        let deleteTask = Task { await controller.deleteMachine(Self.running) }

        await service.waitForLifecycleActionStart()
        #expect(controller.machineActionsInFlight == ["vm-1"])
        controller.resetForSignOut()
        #expect(controller.machineActionsInFlight.isEmpty)
        #expect(controller.lastMachineActionFailure == nil)

        await service.releaseHeldLifecycleAction()
        #expect(await deleteTask.value == false)
        #expect(service.calls.list == 0)
        #expect(controller.machines == .idle)
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

    @Test func changingHiddenMachineIDsInvalidatesObservationConsumers() async {
        let suite = "cmux-cloud-visibility-observation-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = makeController(service: FakeCloudVMService(), visibilityDefaults: defaults)
        let invalidated = TestSignal()

        withObservationTracking {
            _ = controller.hiddenMachineIDs
        } onChange: {
            Task { await invalidated.signal() }
        }

        controller.setMachine(id: "vm-1", hidden: true)
        let invalidationTask = Task<Void, any Error> {
            await invalidated.wait()
        }
        let didInvalidate = (try? await CloudSystemVPNTaskTimeout(timeout: .milliseconds(100)).value(invalidationTask)) != nil

        #expect(didInvalidate)
        #expect(controller.hiddenMachineIDs == ["vm-1"])
    }

    @Test func hiddenMachineIDsStaySeparateWhenTheAccountScopeChanges() throws {
        let suite = "cmux-cloud-visibility-scope-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = FakeCloudVMService()
        let controller = makeController(
            service: service,
            visibilityDefaults: defaults,
            visibilityScope: "https://cmux.example|account-a|team-a"
        )

        controller.setMachine(id: "vm-a", hidden: true)
        controller.setVisibilityScope("https://cmux.example|account-b|team-b")
        #expect(controller.hiddenMachineIDs.isEmpty)

        controller.setMachine(id: "vm-b", hidden: true)
        controller.setVisibilityScope("https://cmux.example|account-a|team-a")
        #expect(controller.hiddenMachineIDs == ["vm-a"])
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
