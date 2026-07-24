import CmuxSimulator
import Foundation
import Testing
@testable import CmuxSimulatorUI

@Suite("Simulator pane startup cancellation")
@MainActor
struct SimulatorPaneCoordinatorCancellationTests {
    @Test("A canceled startup waiter does not cancel pane-owned discovery")
    func canceledStartupWaiterDoesNotCancelDiscovery() async {
        let device = SimulatorDevice(
            id: "phone",
            name: "iPhone",
            runtimeIdentifier: "runtime",
            runtimeName: "iOS 26.5",
            deviceTypeIdentifier: "phone-type",
            family: .iPhone,
            state: .booted,
            isAvailable: true,
            lastBootedAt: nil
        )
        let client = CancellableDiscoveryPaneClient(device: device)
        let coordinator = SimulatorPaneCoordinator(client: client)
        let paneStart = Task { @MainActor in
            await coordinator.start()
        }

        await client.waitForFirstDiscovery()
        let socketWaiter = Task { @MainActor in
            await coordinator.start()
        }
        socketWaiter.cancel()
        await socketWaiter.value

        #expect(coordinator.failure == nil)
        #expect(coordinator.started)
        #expect(await client.discoveryCount() == 1)

        await coordinator.close()
        await paneStart.value
        #expect(coordinator.status == .idle)
    }

    @Test("Cancelled explicit selection stops its activation generation")
    func cancelledSelectionStopsActivation() async {
        let device = SimulatorDevice(
            id: "phone",
            name: "iPhone",
            runtimeIdentifier: "runtime",
            runtimeName: "iOS 26.5",
            deviceTypeIdentifier: "phone-type",
            family: .iPhone,
            state: .shutdown,
            isAvailable: true,
            lastBootedAt: nil
        )
        let client = SimulatorPaneClientSpy(devices: [device], delaysActivation: true)
        let coordinator = SimulatorPaneCoordinator(client: client)
        let selection = Task { @MainActor in
            try await coordinator.selectDeviceAndWait(id: device.id)
        }
        for _ in 0..<100 {
            if await client.activations().count == 1 { break }
            await Task.yield()
        }

        selection.cancel()
        do {
            try await selection.value
            Issue.record("Expected selection cancellation")
        } catch is CancellationError {}
        catch { Issue.record("Unexpected error: \(error)") }

        #expect(await client.activationCancellationCount() == 1)
        #expect(coordinator.selectedDeviceID == nil)
        #expect(coordinator.status == .idle)
        await coordinator.close()
    }

    @Test("Cancelled explicit selection restores the prior device binding")
    func cancelledSelectionRestoresPriorBinding() async {
        let phone = SimulatorDevice(
            id: "phone",
            name: "iPhone",
            runtimeIdentifier: "runtime",
            runtimeName: "iOS 26.5",
            deviceTypeIdentifier: "phone-type",
            family: .iPhone,
            state: .booted,
            isAvailable: true,
            lastBootedAt: nil
        )
        let pad = SimulatorDevice(
            id: "pad",
            name: "iPad",
            runtimeIdentifier: "runtime",
            runtimeName: "iOS 26.5",
            deviceTypeIdentifier: "pad-type",
            family: .iPad,
            state: .shutdown,
            isAvailable: true,
            lastBootedAt: nil
        )
        let client = SimulatorPaneClientSpy(
            devices: [phone, pad],
            delaysActivation: true
        )
        let coordinator = SimulatorPaneCoordinator(client: client)
        coordinator.devices = [phone, pad]
        coordinator.selectedDeviceID = phone.id
        coordinator.status = .streaming

        let selection = Task { @MainActor in
            try await coordinator.selectDeviceAndWait(id: pad.id)
        }
        await waitForActivation(pad.id, client: client)
        selection.cancel()
        _ = await selection.result

        #expect(coordinator.selectedDeviceID == phone.id)
        await waitForActivation(phone.id, client: client)
        await coordinator.close()
    }

    @Test("Discovery cancellation preserves a newer device selection")
    func discoveryCancellationPreservesNewerSelection() async {
        let previous = SimulatorDevice(
            id: "previous",
            name: "Previous iPhone",
            runtimeIdentifier: "runtime",
            runtimeName: "iOS 26.5",
            deviceTypeIdentifier: "phone-type",
            family: .iPhone,
            state: .booted,
            isAvailable: true,
            lastBootedAt: nil
        )
        let newer = SimulatorDevice(
            id: "newer",
            name: "Newer iPad",
            runtimeIdentifier: "runtime",
            runtimeName: "iOS 26.5",
            deviceTypeIdentifier: "pad-type",
            family: .iPad,
            state: .booted,
            isAvailable: true,
            lastBootedAt: nil
        )
        let client = CancellableDiscoveryPaneClient(device: newer)
        let coordinator = SimulatorPaneCoordinator(client: client)
        coordinator.devices = [previous, newer]
        coordinator.selectedDeviceID = previous.id
        coordinator.status = .streaming

        let staleSelection = Task { @MainActor in
            try await coordinator.selectDeviceAndWait(id: previous.id)
        }
        await client.waitForFirstDiscovery()
        coordinator.selectDevice(id: newer.id)
        staleSelection.cancel()
        _ = await staleSelection.result

        #expect(coordinator.selectedDeviceID == newer.id)
        await coordinator.close()
    }

    @Test("A stale discovery snapshot cannot replace a newer device selection")
    func staleDiscoveryCannotReplaceNewerSelection() async {
        let previous = makeDevice(id: "previous", family: .iPhone)
        let newer = makeDevice(id: "newer", family: .iPad)
        let client = StaleDiscoveryPaneClient()
        let coordinator = SimulatorPaneCoordinator(client: client)
        coordinator.devices = [previous, newer]
        coordinator.selectedDeviceID = previous.id
        coordinator.status = .streaming

        let refresh = Task { @MainActor in await coordinator.reloadDevices() }
        await client.waitUntilDiscoveryIsPending()
        coordinator.selectDevice(id: newer.id)
        await client.resumeDiscovery(with: [previous])
        _ = await refresh.value

        #expect(coordinator.selectedDeviceID == newer.id)
        #expect(coordinator.devices.map(\.id) == [previous.id, newer.id])
        await coordinator.close()
    }

    @Test("An older explicit selection cannot replace a newer selection")
    func staleExplicitSelectionCannotReplaceNewerSelection() async {
        let previous = makeDevice(id: "previous", family: .iPhone)
        let newer = makeDevice(id: "newer", family: .iPad)
        let client = StaleDiscoveryPaneClient()
        let coordinator = SimulatorPaneCoordinator(client: client)
        coordinator.devices = [previous, newer]
        coordinator.selectedDeviceID = previous.id
        coordinator.status = .streaming

        let staleSelection = Task { @MainActor in
            try await coordinator.selectDeviceAndWait(id: previous.id)
        }
        await client.waitUntilDiscoveryIsPending()
        coordinator.selectDevice(id: newer.id)
        await client.resumeDiscovery(with: [previous])

        await #expect(throws: CancellationError.self) {
            try await staleSelection.value
        }
        #expect(coordinator.selectedDeviceID == newer.id)
        await coordinator.close()
    }

    @Test("Closing a pane cancels and joins one coalesced UI action")
    func closeCancelsOwnedControlActions() async {
        let client = SimulatorPaneClientSpy(devices: [])
        let coordinator = SimulatorPaneCoordinator(client: client)
        let probe = SimulatorScheduledActionProbe()

        coordinator.scheduleControlAction("capture") { _ in
            await probe.started()
            do {
                try await ContinuousClock().sleep(for: .seconds(30))
            } catch {}
            await probe.finished()
        }
        coordinator.scheduleControlAction("capture") { _ in
            await probe.started()
        }
        await probe.waitUntilStarted()

        await coordinator.close()

        #expect(await probe.startCount == 1)
        #expect(await probe.finishCount == 1)
        #expect(coordinator.controlActionTasks.isEmpty)
    }

    @Test("Device selection started by a control action never joins itself")
    func controlActionSelectionDoesNotJoinItself() async {
        let device = makeDevice(id: "phone", family: .iPhone)
        let client = SimulatorPaneClientSpy(devices: [device])
        let coordinator = SimulatorPaneCoordinator(client: client)
        coordinator.devices = [device]

        let task = coordinator.startControlAction("control-socket-select") { coordinator in
            try? await coordinator.selectDeviceAndWait(id: device.id)
        }

        for _ in 0..<100 {
            if await client.activations().contains(where: { $0.id == device.id }) { break }
            await Task.yield()
        }
        let activated = await client.activations().contains(where: { $0.id == device.id })
        #expect(activated)

        if activated {
            await task?.value
            await coordinator.close()
        }
    }

    private func makeDevice(
        id: String,
        family: SimulatorDeviceFamily
    ) -> SimulatorDevice {
        SimulatorDevice(
            id: id,
            name: id,
            runtimeIdentifier: "runtime",
            runtimeName: "iOS 26.5",
            deviceTypeIdentifier: "\(id)-type",
            family: family,
            state: .booted,
            isAvailable: true,
            lastBootedAt: nil
        )
    }

    private func waitForActivation(
        _ deviceID: String,
        client: SimulatorPaneClientSpy
    ) async {
        for _ in 0..<1_000 {
            if await client.activations().contains(where: { $0.id == deviceID }) { return }
            await Task.yield()
        }
        Issue.record("Expected activation for \(deviceID)")
    }
}

private actor SimulatorScheduledActionProbe {
    private(set) var startCount = 0
    private(set) var finishCount = 0

    func started() { startCount += 1 }
    func finished() { finishCount += 1 }

    func waitUntilStarted() async {
        while startCount == 0 { await Task.yield() }
    }
}

private actor StaleDiscoveryPaneClient: SimulatorPaneClient {
    private let eventStream: SimulatorWorkerEventStream
    private let eventContinuation: SimulatorWorkerEventStream.Continuation
    private var discoveryContinuation: CheckedContinuation<[SimulatorDevice], Never>?
    private var discoveryWaiters: [CheckedContinuation<Void, Never>] = []

    init() {
        let source = SimulatorWorkerEventStreamSource(
            maximumBufferedBytes: 1_024,
            maximumBufferedEvents: 8,
            onTermination: {}
        )
        eventStream = source.stream
        eventContinuation = source.continuation
    }

    func discoverDevices() async throws -> [SimulatorDevice] {
        let waiters = discoveryWaiters
        discoveryWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        return await withCheckedContinuation { discoveryContinuation = $0 }
    }

    func waitUntilDiscoveryIsPending() async {
        if discoveryContinuation != nil { return }
        await withCheckedContinuation { discoveryWaiters.append($0) }
    }

    func resumeDiscovery(with devices: [SimulatorDevice]) {
        discoveryContinuation?.resume(returning: devices)
        discoveryContinuation = nil
    }

    func activateDevice(id: String, geometry: SimulatorSurfaceGeometry?) async throws {}
    func shutdownDevice(id: String) async throws {}
    func subscribe() async -> SimulatorWorkerEventStream { eventStream }
    func send(_ message: SimulatorWorkerInbound) async {}
    func synchronizeOrientation(
        _ orientation: SimulatorOrientation
    ) async throws -> SimulatorDisplayMetadata? { nil }
    func perform(_ action: SimulatorControlAction) async throws -> SimulatorControlResult { .none }
    func invalidateWorker() async {}
    func stop() async { await eventContinuation.finish() }
}
