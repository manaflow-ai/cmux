import CmuxSimulator
import Foundation
import Testing
@testable import CmuxSimulatorUI

@Suite("Simulator pane coordinator")
@MainActor
struct SimulatorPaneCoordinatorTests {
    @Test("Native input capture follows worker state and toggles cleanly")
    func nativeInputCapture() async {
        let client = SimulatorPaneClientSpy(devices: [
            Self.device(id: "pad", family: .iPad, state: .booted),
        ])
        let coordinator = SimulatorPaneCoordinator(client: client)
        await coordinator.start()

        coordinator.togglePointerCapture()
        await eventually {
            await client.messages().contains(.setHIDCapture(.pointerAndKeyboard))
        }
        await client.emit(.message(.hidCapture(.pointerAndKeyboard)))
        await eventually { coordinator.hidCaptureMode == .pointerAndKeyboard }

        coordinator.togglePointerCapture()
        await eventually {
            await client.messages().contains(.setHIDCapture(.none))
        }

        await client.emit(.message(.hidCapture(.none)))
        await eventually { coordinator.hidCaptureMode == .none }
        coordinator.toggleKeyboardCapture()
        await eventually {
            await client.messages().contains(.setHIDCapture(.keyboard))
        }
    }

    @Test("Discovery filters unavailable and non-mobile devices")
    func discoveryFiltering() async {
        let client = SimulatorPaneClientSpy(devices: [
            Self.device(id: "phone", family: .iPhone, state: .booted),
            Self.device(id: "pad", family: .iPad, state: .shutdown),
            Self.device(id: "watch", family: .watch, state: .booted),
            Self.device(id: "missing", family: .iPhone, state: .shutdown, isAvailable: false),
        ])
        let coordinator = SimulatorPaneCoordinator(client: client)

        await coordinator.start()

        #expect(coordinator.devices.map { $0.id } == ["phone", "pad"])
        #expect(coordinator.selectedDeviceID == "phone")
    }

    @Test("Worker events update live state and crashes preserve the host")
    func workerEventState() async {
        let client = SimulatorPaneClientSpy(devices: [Self.device(id: "phone", family: .iPhone, state: .booted)])
        let coordinator = SimulatorPaneCoordinator(client: client)
        coordinator.setPaneVisibility(true)
        await coordinator.start()

        await client.emit(SimulatorWorkerEvent.message(.capabilities([.framebuffer, .touch])))
        let frameTransport = simulatorFrameTransportDescriptor(42)
        await client.emit(SimulatorWorkerEvent.message(.frameTransport(frameTransport)))
        await client.emit(SimulatorWorkerEvent.message(.status(.streaming)))
        await eventually {
            coordinator.frameTransport == frameTransport
                && coordinator.status == SimulatorSessionStatus.streaming
        }

        #expect(coordinator.capabilities == Set([
            SimulatorCapability.framebuffer,
            .touch,
            .userInterfaceSettings,
        ]))

        await client.emit(SimulatorWorkerEvent.workerStopped)
        await eventually { coordinator.status == SimulatorSessionStatus.workerCrashed }

        #expect(coordinator.frameTransport == nil)
    }

    @Test("Selection delegates boot and attachment to the client")
    func deviceActivation() async {
        let client = SimulatorPaneClientSpy(devices: [Self.device(id: "pad", family: .iPad, state: .shutdown)])
        let coordinator = SimulatorPaneCoordinator(client: client)
        await coordinator.start()

        coordinator.updateGeometry(SimulatorSurfaceGeometry(width: 640, height: 800, scale: 2))
        coordinator.selectDevice(id: "pad")

        await eventually {
            await client.activations().last?.geometry
                == SimulatorSurfaceGeometry(width: 640, height: 800, scale: 2)
        }
        let activations = await client.activations()
        #expect(activations.last?.id == "pad")
        #expect(activations.last?.geometry == SimulatorSurfaceGeometry(width: 640, height: 800, scale: 2))
    }

    @Test("A new pane establishes portrait orientation after attachment")
    func newPaneEstablishesPortraitOrientation() async {
        let client = SimulatorPaneClientSpy(devices: [
            Self.device(id: "phone", family: .iPhone, state: .booted),
        ])
        let coordinator = SimulatorPaneCoordinator(client: client)

        await coordinator.start()
        await eventually {
            await client.messages().contains(.rotate(.portrait))
        }

        let messages = await client.messages()
        #expect(messages.filter { $0 == .rotate(.portrait) }.count == 1)
    }

    @Test("Hidden panes suspend and resume framebuffer publication")
    func frameVisibility() async {
        let client = SimulatorPaneClientSpy(devices: [
            Self.device(id: "phone", family: .iPhone, state: .booted),
        ])
        let coordinator = SimulatorPaneCoordinator(client: client)
        coordinator.setFrameVisibility(true)
        await coordinator.start()
        await eventually { coordinator.status == .streaming }
        await client.emit(.message(.frameTransport(simulatorFrameTransportDescriptor(49))))
        await eventually { coordinator.frameTransport != nil }

        coordinator.setFrameVisibility(false)
        await eventually {
            await client.messages().contains(.setFramebufferPublishing(false))
        }
        #expect(coordinator.frameTransport == nil)

        coordinator.setFrameVisibility(true)
        await eventually {
            await client.messages().contains(.setFramebufferPublishing(true))
        }
    }

    @Test("Host visibility controls every occlusion-sensitive resource")
    func paneVisibility() {
        let coordinator = SimulatorPaneCoordinator(client: SimulatorPaneClientSpy(devices: []))

        #expect(!coordinator.frameIsVisible)
        #expect(!coordinator.liveStatusIsVisible)
        #expect(!coordinator.accessibilityOverlayIsVisible)

        coordinator.setPaneVisibility(true)

        #expect(coordinator.frameIsVisible)
        #expect(!coordinator.liveStatusIsVisible)
        #expect(coordinator.accessibilityOverlayIsVisible)

        coordinator.showsTools = true
        #expect(coordinator.liveStatusIsVisible)

        coordinator.showsTools = false
        #expect(!coordinator.liveStatusIsVisible)
    }

    @Test("Explicit recovery returns only after the selected device streams")
    func explicitRecoveryWaitsForActivation() async throws {
        let client = SimulatorPaneClientSpy(devices: [
            Self.device(id: "phone", family: .iPhone, state: .booted),
        ])
        let coordinator = SimulatorPaneCoordinator(client: client)
        await coordinator.reloadDevices()

        try await coordinator.recoverAndWait()

        #expect(coordinator.status == .streaming)
        #expect(await client.activations().map(\.id) == ["phone"])
    }

    @Test("Optional capability commands wait for hydration after core streaming")
    func optionalCapabilityWaitsForHydration() async throws {
        let client = SimulatorPaneClientSpy(devices: [])
        let coordinator = SimulatorPaneCoordinator(client: client)
        await coordinator.start()
        await client.emit(.message(.status(.streaming)))
        await eventually { coordinator.status == .streaming }

        let waiter = Task { @MainActor in
            try await coordinator.waitForCapabilityHydration()
        }
        await eventually { coordinator.capabilityHydrationWaiters.count == 1 }
        #expect(!coordinator.supports(.accessibility))

        await client.emit(.message(.capabilitiesHydrated([.accessibility, .framebuffer])))
        try await waiter.value

        #expect(coordinator.supports(.accessibility))
        #expect(coordinator.capabilityHydrationWaiters.isEmpty)
    }

    @Test("Restored panes without a persisted UDID require explicit selection")
    func restoredPaneWithoutIdentityFailsClosed() async throws {
        let client = SimulatorPaneClientSpy(devices: [
            Self.device(id: "phone", family: .iPhone, state: .booted),
        ])
        let coordinator = SimulatorPaneCoordinator(
            client: client,
            requiresExplicitDeviceSelection: true
        )

        await coordinator.reloadDevices()

        #expect(coordinator.selectedDeviceID == nil)
        #expect(coordinator.failure?.code == "simulator_saved_device_unavailable")
        #expect(await client.activations().isEmpty)

        try await coordinator.selectDeviceAndWait(id: "phone")
        #expect(coordinator.selectedDeviceID == "phone")
        #expect(coordinator.status == .streaming)
    }

    @Test("Restoration selects the exact persisted UDID ahead of a booted device")
    func restorationHonorsAvailableIdentity() async {
        let client = SimulatorPaneClientSpy(devices: [
            Self.device(id: "saved", family: .iPhone, state: .shutdown),
            Self.device(id: "other", family: .iPhone, state: .booted),
        ])
        let coordinator = SimulatorPaneCoordinator(
            client: client,
            preferredDeviceID: "saved",
            preferredRuntimeIdentifier: "runtime",
            preferredDeviceTypeIdentifier: "type"
        )

        await coordinator.reloadDevices()

        #expect(coordinator.selectedDeviceID == "saved")
        #expect(await client.activations().isEmpty)
    }

    @Test("A selected UDID disappearing fails closed and invalidates its worker")
    func selectedDeviceDisappearanceFailsClosed() async throws {
        let client = SimulatorPaneClientSpy(devices: [
            Self.device(id: "selected", family: .iPhone, state: .booted),
            Self.device(id: "other", family: .iPhone, state: .booted),
        ])
        let coordinator = SimulatorPaneCoordinator(client: client)
        await coordinator.reloadDevices()
        try await coordinator.selectDeviceAndWait(id: "selected")
        await client.setDevices([
            Self.device(id: "other", family: .iPhone, state: .booted),
        ])

        await coordinator.reloadDevices()

        #expect(coordinator.selectedDeviceID == nil)
        #expect(coordinator.failure?.code == "simulator_saved_device_unavailable")
        #expect(coordinator.frameTransport == nil)
        #expect(await client.invalidationCount() == 1)
        #expect(await client.activations().map(\.id) == ["selected"])

        await coordinator.reloadDevices()
        #expect(coordinator.selectedDeviceID == nil)
        #expect(await client.invalidationCount() == 1)
        #expect(await client.activations().map(\.id) == ["selected"])
    }

    @Test("Explicit selection survives its own missing-device cleanup")
    func explicitSelectionAfterDisappearance() async throws {
        let selected = Self.device(id: "selected", family: .iPhone, state: .booted)
        let replacement = Self.device(id: "replacement", family: .iPad, state: .booted)
        let client = SimulatorPaneClientSpy(devices: [selected, replacement])
        let coordinator = SimulatorPaneCoordinator(client: client)
        await coordinator.reloadDevices()
        try await coordinator.selectDeviceAndWait(id: selected.id)
        await client.setDevices([replacement])

        try await coordinator.selectDeviceAndWait(id: replacement.id)

        #expect(coordinator.selectedDeviceID == replacement.id)
        #expect(coordinator.status == .streaming)
        await coordinator.close()
    }

    @Test("Explicit device selection waits for the requested iPad")
    func explicitDeviceSelection() async throws {
        let client = SimulatorPaneClientSpy(devices: [
            Self.device(id: "phone", family: .iPhone, state: .booted),
            Self.device(id: "pad", family: .iPad, state: .shutdown),
        ])
        let coordinator = SimulatorPaneCoordinator(client: client)
        await coordinator.reloadDevices()

        try await coordinator.selectDeviceAndWait(id: "pad")

        #expect(coordinator.selectedDeviceID == "pad")
        #expect(coordinator.status == .streaming)
        #expect(await client.activations().last?.id == "pad")
    }

    @Test("Explicit startup never activates the persisted or default device first")
    func explicitStartupActivatesOnlyRequestedDevice() async throws {
        let client = SimulatorPaneClientSpy(devices: [
            Self.device(id: "phone", family: .iPhone, state: .booted),
            Self.device(id: "pad", family: .iPad, state: .shutdown),
        ])
        let coordinator = SimulatorPaneCoordinator(
            client: client,
            preferredDeviceID: "phone"
        )

        await coordinator.prepareForExplicitDeviceSelection()
        #expect(await client.activations().isEmpty)

        try await coordinator.selectDeviceAndWait(id: "pad")

        #expect(await client.activations().map(\.id) == ["pad"])
    }

    @Test("Context readiness waits for a dormant selected device to stream")
    func contextReadinessWaitsForActivation() async throws {
        let client = SimulatorPaneClientSpy(
            devices: [Self.device(id: "pad", family: .iPad, state: .shutdown)],
            delaysActivation: true
        )
        let coordinator = SimulatorPaneCoordinator(client: client)
        await coordinator.start()
        await eventually { await client.hasDelayedActivation() }

        let readiness = Task { try await coordinator.waitForSelectedDeviceStreaming() }
        await Task.yield()
        #expect(coordinator.status == .connecting)

        await client.resumeActivation()
        try await readiness.value

        #expect(coordinator.status == .streaming)
        #expect(await client.activations().map(\.id) == ["pad"])
    }

    @Test("Cancelling context readiness preserves pane-owned activation")
    func cancellingContextReadinessPreservesActivation() async {
        let client = SimulatorPaneClientSpy(
            devices: [Self.device(id: "phone", family: .iPhone, state: .shutdown)],
            delaysActivation: true
        )
        let coordinator = SimulatorPaneCoordinator(client: client)
        await coordinator.start()
        await eventually { await client.hasDelayedActivation() }

        let readiness = Task { try await coordinator.waitForSelectedDeviceStreaming() }
        readiness.cancel()
        await #expect(throws: CancellationError.self) {
            try await readiness.value
        }
        #expect(await client.activationCancellationCount() == 0)

        await client.resumeActivation()
        await eventually { coordinator.status == .streaming }
    }

    @Test("Swipe commands stay ordered on one outbox")
    func swipeOrdering() async {
        let client = SimulatorPaneClientSpy(devices: [])
        let coordinator = SimulatorPaneCoordinator(client: client)
        await coordinator.start()

        coordinator.swipe(
            from: SimulatorPoint(x: 0.5, y: 0.9),
            to: SimulatorPoint(x: 0.5, y: 0.1),
            edge: .bottom
        )

        await eventually { await client.messages().count == 8 }
        let phases = await client.messages().compactMap { message -> SimulatorTouchPhase? in
            guard case let .pointer(event) = message else { return nil }
            return event.phase
        }
        #expect(phases == [.began, .moved, .moved, .moved, .moved, .moved, .moved, .ended])
    }

    @Test("Text validates completely and resolves only the matching worker completion")
    func correlatedTextInput() async throws {
        let client = SimulatorPaneClientSpy(devices: [])
        let coordinator = SimulatorPaneCoordinator(client: client)
        await coordinator.start()
        await client.emit(.message(.capabilities([.keyboard])))
        await client.emit(.message(.status(.streaming)))
        await eventually { coordinator.status == .streaming && coordinator.supports(.keyboard) }

        #expect(coordinator.typeText("a🙂") == .failure(.encoding(.unsupportedScalar(
            value: 0x1F642,
            scalarIndex: 1
        ))))
        let oversized = String(
            repeating: "a",
            count: SimulatorTextInputSequence.maximumUTF8ByteCount + 1
        )
        guard case .failure(.encoding(.tooLong)) = coordinator.typeText(oversized) else {
            Issue.record("Expected oversize validation failure")
            return
        }
        #expect(await client.messages().allSatisfy { message in
            if case .typeText = message { return false }
            return true
        })

        let completions = LockedTextInputCompletions()
        let submission = coordinator.beginTypeText("A?", completion: { succeeded in
            completions.append(succeeded)
        })
        guard case let .success(submitted) = submission else {
            Issue.record("Expected text submission")
            return
        }
        #expect(submitted.characterCount == 2)
        await eventually {
            await client.messages().contains { if case .typeText = $0 { true } else { false } }
        }
        let message = try #require(await client.messages().first { message in
            if case .typeText = message { return true }
            return false
        })
        guard case let .typeText(requestID, sequence) = message else { return }
        #expect(sequence == (try SimulatorUSKeyboardTextEncoder().encode("A?")))

        await client.emit(.message(.textInput(requestID: UUID(), succeeded: true)))
        await Task.yield()
        #expect(completions.values().isEmpty)

        await client.emit(.message(.textInput(requestID: requestID, succeeded: true)))
        await eventually { completions.values() == [true] }
    }

    @Test("Cancelling text invalidates in-flight worker state and releases its request ID")
    func cancelQueuedTextInput() async {
        let client = SimulatorPaneClientSpy(devices: [], delaysInvalidation: true)
        let coordinator = SimulatorPaneCoordinator(client: client)
        await coordinator.start()
        await client.emit(.message(.capabilities([.keyboard])))
        await client.emit(.message(.status(.streaming)))
        await eventually { coordinator.status == .streaming && coordinator.supports(.keyboard) }

        let completions = LockedTextInputCompletions()
        guard case let .success(submission) = coordinator.beginTypeText("cancel", completion: { succeeded in
            completions.append(succeeded)
        }) else {
            Issue.record("Expected text submission")
            return
        }
        coordinator.cancelTextInput(requestID: submission.requestIdentifier)

        await eventually { await client.invalidationCount() == 1 }
        #expect(coordinator.status == .connecting)
        guard case .failure(.inputUnavailable) = coordinator.beginTypeText(
            "too soon",
            completion: nil
        ) else {
            Issue.record("Expected input to remain gated during worker invalidation")
            return
        }

        await client.resumeInvalidation()
        await eventually { coordinator.cancelledTextInputRequestIDs.isEmpty }
        #expect(coordinator.status == .workerCrashed)
        #expect(completions.values() == [false])
    }

    @Test("Worker teardown fails a pending text receipt exactly once")
    func textInputTeardown() async {
        let client = SimulatorPaneClientSpy(devices: [])
        let coordinator = SimulatorPaneCoordinator(client: client)
        await coordinator.start()
        await client.emit(.message(.capabilities([.keyboard])))
        await client.emit(.message(.status(.streaming)))
        await eventually { coordinator.status == .streaming && coordinator.supports(.keyboard) }

        let completions = LockedTextInputCompletions()
        let submission = coordinator.beginTypeText("retry", completion: { succeeded in
            completions.append(succeeded)
        })
        guard case let .success(submitted) = submission else {
            Issue.record("Expected text submission")
            return
        }
        #expect(submitted.characterCount == 5)
        await client.emit(.workerStopped)
        await client.emit(.workerStopped)
        await eventually { completions.values() == [false] }
    }

    @Test("Persistence never rebinds a missing UDID to a matching device type")
    func persistenceFailsClosed() async throws {
        let older = Self.device(
            id: "older",
            family: .iPhone,
            state: .shutdown,
            runtimeIdentifier: "runtime-26",
            deviceTypeIdentifier: "phone-pro",
            lastBootedAt: Date(timeIntervalSince1970: 10)
        )
        let newer = Self.device(
            id: "newer",
            family: .iPhone,
            state: .shutdown,
            runtimeIdentifier: "runtime-26",
            deviceTypeIdentifier: "phone-pro",
            lastBootedAt: Date(timeIntervalSince1970: 20)
        )
        let client = SimulatorPaneClientSpy(devices: [older, newer])
        let coordinator = SimulatorPaneCoordinator(
            client: client,
            preferredDeviceID: "deleted-device",
            preferredRuntimeIdentifier: "runtime-26",
            preferredDeviceTypeIdentifier: "phone-pro"
        )

        await coordinator.start()

        let failure = try #require(coordinator.failure)
        #expect(coordinator.selectedDeviceID == nil)
        #expect(failure.code == "simulator_saved_device_unavailable")
        #expect(coordinator.status == .failed(failure))
        #expect(await client.activations().isEmpty)
    }

    @Test("Closing joins activation and prevents later worker restarts")
    func closeIsTerminal() async {
        let client = SimulatorPaneClientSpy(devices: [
            Self.device(id: "one", family: .iPhone, state: .booted),
            Self.device(id: "two", family: .iPad, state: .shutdown),
        ])
        let coordinator = SimulatorPaneCoordinator(client: client)
        coordinator.setPaneVisibility(true)
        await coordinator.start()
        await eventually { await client.activations().count == 1 }

        await coordinator.close()
        coordinator.selectDevice(id: "two")
        await coordinator.start()
        await Task.yield()

        #expect(await client.activations().count == 1)
        #expect(await client.stopCount() == 1)
    }

    @Test("Dropped apps and media route through typed native actions")
    func droppedFiles() async {
        let client = SimulatorPaneClientSpy(devices: [
            Self.device(id: "phone", family: .iPhone, state: .booted),
        ])
        let coordinator = SimulatorPaneCoordinator(client: client)
        #expect(!coordinator.canImportDroppedFiles([
            URL(fileURLWithPath: "/tmp/Fixture.app"),
        ]))
        await coordinator.start()

        #expect(coordinator.canImportDroppedFiles([
            URL(fileURLWithPath: "/tmp/Fixture.app"),
        ]))
        #expect(!coordinator.canImportDroppedFiles([
            URL(fileURLWithPath: "/tmp/notes.txt"),
        ]))

        await coordinator.importDroppedFiles([
            URL(fileURLWithPath: "/tmp/Fixture.app"),
            URL(fileURLWithPath: "/tmp/photo.png"),
            URL(fileURLWithPath: "/tmp/photo.heif"),
            URL(fileURLWithPath: "/tmp/photo.webp"),
            URL(fileURLWithPath: "/tmp/notes.txt"),
        ])

        let actions = await client.actions()
        #expect(actions.contains(.installApplication(
            deviceID: "phone",
            applicationURL: URL(fileURLWithPath: "/tmp/Fixture.app")
        )))
        #expect(actions.contains(.addMedia(
            deviceID: "phone",
            urls: [
                URL(fileURLWithPath: "/tmp/photo.png"),
                URL(fileURLWithPath: "/tmp/photo.heif"),
                URL(fileURLWithPath: "/tmp/photo.webp"),
            ]
        )))
        #expect(!actions.contains(.addMedia(
            deviceID: "phone",
            urls: [URL(fileURLWithPath: "/tmp/notes.txt")]
        )))
    }

    @Test("A failed dropped app install keeps its visible error")
    func failedDroppedApplicationInstall() async {
        let client = SimulatorPaneClientSpy(
            devices: [Self.device(id: "phone", family: .iPhone, state: .booted)],
            failsApplicationInstall: true
        )
        let coordinator = SimulatorPaneCoordinator(client: client)
        await coordinator.start()

        await coordinator.importDroppedFiles([
            URL(fileURLWithPath: "/tmp/Invalid.ipa"),
        ])
        let actions = await client.actions()

        #expect(coordinator.controlFailure?.code == "fixture_install_failed")
        #expect(!actions.contains { action in
            if case .listApplications = action { return true }
            return false
        })
    }

    @Test("A successful media import cannot erase a failed dropped app install")
    func mixedDropPreservesApplicationInstallFailure() async {
        let client = SimulatorPaneClientSpy(
            devices: [Self.device(id: "phone", family: .iPhone, state: .booted)],
            failsApplicationInstall: true
        )
        let coordinator = SimulatorPaneCoordinator(client: client)
        await coordinator.start()

        await coordinator.importDroppedFiles([
            URL(fileURLWithPath: "/tmp/Invalid.ipa"),
            URL(fileURLWithPath: "/tmp/photo.png"),
        ])

        #expect(coordinator.controlFailure?.code == "fixture_install_failed")
        #expect(await client.actions().contains(.addMedia(
            deviceID: "phone",
            urls: [URL(fileURLWithPath: "/tmp/photo.png")]
        )))
    }

    @Test("Recoverable tool failures keep a live display interactive")
    func recoverableToolFailure() async {
        let client = SimulatorPaneClientSpy(devices: [
            Self.device(id: "phone", family: .iPhone, state: .booted),
        ])
        let coordinator = SimulatorPaneCoordinator(client: client)
        coordinator.setPaneVisibility(true)
        await coordinator.start()
        let frameTransport = simulatorFrameTransportDescriptor(42)
        await client.emit(.message(.frameTransport(frameTransport)))
        await client.emit(.message(.status(.streaming)))
        await client.emit(.message(.failure(SimulatorFailure(
            code: "unsupported_tool",
            message: "Unsupported",
            isRecoverable: true
        ))))
        await eventually { coordinator.controlFailure?.code == "unsupported_tool" }

        #expect(coordinator.status == .streaming)
        #expect(coordinator.frameTransport == frameTransport)
    }

    @Test("Closing disables an active injected camera before stopping the client")
    func closeDisablesCamera() async {
        let client = SimulatorPaneClientSpy(devices: [
            Self.device(id: "phone", family: .iPhone, state: .booted),
        ])
        let coordinator = SimulatorPaneCoordinator(client: client)
        await coordinator.start()
        await coordinator.useCameraPlaceholder()

        await coordinator.close()

        let actions = await client.actions()
        #expect(actions.contains(.configureCamera(.disabled)))
        #expect(await client.stopCount() == 1)
    }

    @Test("Device switching stops when camera cleanup fails")
    func deviceSwitchStopsOnCameraCleanupFailure() async {
        let client = SimulatorPaneClientSpy(
            devices: [
                Self.device(id: "one", family: .iPhone, state: .booted),
                Self.device(id: "two", family: .iPhone, state: .booted),
            ],
            failsCameraDisable: true
        )
        let coordinator = SimulatorPaneCoordinator(client: client)
        await coordinator.start()
        await coordinator.useCameraPlaceholder()

        coordinator.selectDevice(id: "two")
        await eventually { coordinator.failure?.code == "fixture_camera_cleanup_failed" }

        #expect(coordinator.cameraConfiguration == .placeholder)
        #expect(await client.activations().map(\.id) == ["one"])

        await coordinator.close()
    }

    func eventually(
        _ condition: @escaping @MainActor @Sendable () async -> Bool
    ) async {
        for _ in 0..<200 {
            if await condition() { return }
            await Task.yield()
        }
        Issue.record("Condition did not become true")
    }

    static func device(
        id: String,
        family: SimulatorDeviceFamily,
        state: SimulatorDeviceState,
        isAvailable: Bool = true,
        runtimeIdentifier: String = "runtime",
        deviceTypeIdentifier: String = "type",
        lastBootedAt: Date? = nil
    ) -> SimulatorDevice {
        SimulatorDevice(
            id: id,
            name: id,
            runtimeIdentifier: runtimeIdentifier,
            runtimeName: "iOS 26.5",
            deviceTypeIdentifier: deviceTypeIdentifier,
            family: family,
            state: state,
            isAvailable: isAvailable,
            lastBootedAt: lastBootedAt
        )
    }

    static func application(id: String, type: String) -> SimulatorInstalledApplication {
        SimulatorInstalledApplication(
            id: id,
            name: id,
            displayName: id,
            executableName: id,
            path: "/Applications/\(id).app",
            applicationType: type
        )
    }
}
