import CmuxSimulator
import Foundation
import Testing
@testable import CmuxSimulatorUI

@MainActor
extension SimulatorPaneCoordinatorTests {
    @Test("Recovery retries device discovery after an initial failure")
    func recoveryRetriesDeviceDiscovery() async throws {
        let phone = Self.device(id: "phone", family: .iPhone, state: .booted)
        let client = LocationLifecyclePaneClient(devices: [phone])
        let coordinator = SimulatorPaneCoordinator(client: client)
        await client.setDiscoveryFailure(SimulatorFailure(
            code: "discovery_unavailable",
            message: "Discovery is unavailable.",
            isRecoverable: true
        ))

        await coordinator.reloadDevices()
        #expect(coordinator.selectedDeviceID == nil)

        await client.setDiscoveryFailure(nil)
        try await coordinator.recoverAndWait()

        #expect(coordinator.selectedDeviceID == phone.id)
        #expect(coordinator.status == .streaming)
        #expect(await client.operations().contains("activate:\(phone.id)"))
    }

    @Test("A discovery refresh failure preserves an active stream")
    func discoveryRefreshFailurePreservesStream() async throws {
        let phone = Self.device(id: "phone", family: .iPhone, state: .booted)
        let client = LocationLifecyclePaneClient(devices: [phone])
        let coordinator = SimulatorPaneCoordinator(client: client)
        await coordinator.reloadDevices()
        try await coordinator.recoverAndWait()
        await client.setDiscoveryFailure(SimulatorFailure(
            code: "discovery_unavailable",
            message: "Discovery is unavailable.",
            isRecoverable: true
        ))

        await coordinator.reloadDevices()

        #expect(coordinator.status == .streaming)
        #expect(coordinator.failure?.code == "discovery_unavailable")

        await client.setDiscoveryFailure(nil)
        await coordinator.reloadDevices()

        #expect(coordinator.status == .streaming)
        #expect(coordinator.failure == nil)
    }

    @Test("Camera status hydrates and targeting exposes only user-installed apps")
    func cameraStatusAndApplicationFiltering() async {
        let client = SimulatorPaneClientSpy(
            devices: [Self.device(id: "phone", family: .iPhone, state: .booted)],
            applications: [
                Self.application(id: "com.example.user", type: "User"),
                Self.application(id: "com.apple.Preferences", type: "System"),
            ]
        )
        let coordinator = SimulatorPaneCoordinator(client: client)
        await coordinator.start()
        await coordinator.refreshApplications()
        let status = SimulatorCameraStatus(
            configuration: .hostCamera(deviceID: "camera-1"),
            mirrorMode: .on,
            injectedBundleIdentifiers: ["com.example.user"],
            hostCameras: [SimulatorHostCameraDevice(id: "camera-1", name: "Studio Camera")]
        )
        await client.emit(.message(.cameraStatus(requestID: UUID(), status)))
        await eventually { coordinator.cameraStatus == status }

        #expect(coordinator.userInstalledApplications.map(\.id) == ["com.example.user"])
        #expect(coordinator.cameraConfiguration == .hostCamera(deviceID: "camera-1"))
    }

    @Test("Foreground camera intent reinjects after the foreground app changes")
    func foregroundCameraReinjectsNewApplication() async {
        let client = SimulatorPaneClientSpy(devices: [])
        let coordinator = SimulatorPaneCoordinator(client: client)
        coordinator.cameraStatus = SimulatorCameraStatus(
            configuration: .placeholder,
            mirrorMode: .auto,
            injectedBundleIdentifiers: ["com.example.app-a"],
            targets: [SimulatorCameraTargetStatus(
                bundleIdentifier: "com.example.app-a",
                processIdentifier: 100,
                isAlive: true,
                isAttached: true
            )],
            hostCameras: []
        )
        coordinator.foregroundApplication = SimulatorApplicationInfo(
            bundleIdentifier: "com.example.app-b",
            processIdentifier: 200,
            name: "App B",
            version: nil,
            build: nil,
            minimumOSVersion: nil,
            isReactNative: false
        )

        await coordinator.useCameraPlaceholder()

        let actions = await client.actions()
        #expect(actions.contains(.configureCamera(.placeholder)))
        #expect(!actions.contains(.switchCameraSource(.placeholder)))
    }

    @Test("Action history keeps the newest five hundred stable entries")
    func actionHistoryIsBounded() async throws {
        let client = SimulatorPaneClientSpy(devices: [
            Self.device(id: "phone", family: .iPhone, state: .booted),
        ])
        let coordinator = SimulatorPaneCoordinator(client: client)
        await coordinator.start()

        try await coordinator.perform(.openURL(
            deviceID: "phone",
            url: URL(string: "https://example.com")!
        ))
        #expect(coordinator.actionLog.first?.action == "open_url")
        #expect(coordinator.actionLog.first?.succeeded == true)

        for index in 0..<525 {
            coordinator.receive(.message(.actionLog(SimulatorActionLogEntry(
                id: UUID(),
                timestamp: Date(timeIntervalSince1970: TimeInterval(index)),
                action: "worker-\(index)",
                summary: "worker-\(index)",
                succeeded: true
            ))))
        }

        #expect(coordinator.actionLog.count == 500)
        #expect(coordinator.actionLog.first?.action == "worker-524")
        #expect(coordinator.actionLog.last?.action == "worker-25")
    }

    @Test("Interactive actions keep the worker's single authoritative history entry")
    func interactiveActionHistoryHasOneWriter() async throws {
        let coordinator = SimulatorPaneCoordinator(client: SimulatorPaneClientSpy(devices: []))

        try await coordinator.perform(.interactive(.hardwareButton(.home)))
        coordinator.receive(.message(.actionLog(SimulatorActionLogEntry(
            id: UUID(),
            timestamp: Date(),
            action: "button",
            summary: "home",
            succeeded: true
        ))))

        #expect(coordinator.actionLog.map(\.action) == ["button"])
    }

    @Test("Cancellation racing a successful result preserves the commit boundary")
    func cancellationAfterSuccessfulResult() async throws {
        let client = SimulatorPaneClientSpy(
            devices: [],
            cancelsControlActionBeforeReturning: true
        )
        let coordinator = SimulatorPaneCoordinator(client: client)
        let operation = Task {
            try await coordinator.perform(.setInterface(
                deviceID: "phone",
                setting: .appearance(.dark)
            ))
        }

        let result = try await operation.value

        #expect(result == .none)
        #expect(operation.isCancelled)
        #expect(coordinator.controlFailure == nil)
        #expect(coordinator.actionLog.isEmpty)
    }

    @Test("Action history is preserved separately for each selected device")
    func actionHistoryIsDeviceScoped() async {
        let client = SimulatorPaneClientSpy(devices: [
            Self.device(id: "phone", family: .iPhone, state: .booted),
            Self.device(id: "pad", family: .iPad, state: .shutdown),
        ])
        let coordinator = SimulatorPaneCoordinator(client: client)
        await coordinator.start()

        coordinator.receive(.message(.actionLog(SimulatorActionLogEntry(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 1),
            action: "phone-action",
            summary: "phone-action",
            succeeded: true
        ))))
        coordinator.selectDevice(id: "pad")
        coordinator.receive(.message(.actionLog(SimulatorActionLogEntry(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 2),
            action: "pad-action",
            summary: "pad-action",
            succeeded: true
        ))))

        coordinator.selectDevice(id: "phone")
        #expect(coordinator.actionLog.map(\.action) == ["phone-action"])

        coordinator.selectDevice(id: "pad")
        #expect(coordinator.actionLog.map(\.action) == ["pad-action"])
    }

    @Test("Discovery prunes removed history and fails closed when the selected device disappears")
    func actionHistoryPrunesRemovedDevices() async {
        let phone = Self.device(id: "phone", family: .iPhone, state: .booted)
        let pad = Self.device(id: "pad", family: .iPad, state: .shutdown)
        let client = LocationLifecyclePaneClient(devices: [phone, pad])
        let coordinator = SimulatorPaneCoordinator(client: client)
        await coordinator.start()

        coordinator.receive(.message(.actionLog(SimulatorActionLogEntry(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 1),
            action: "phone-action",
            summary: "phone-action",
            succeeded: true
        ))))
        coordinator.selectDevice(id: "pad")
        coordinator.receive(.message(.actionLog(SimulatorActionLogEntry(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 2),
            action: "pad-action",
            summary: "pad-action",
            succeeded: true
        ))))
        await client.setDevices([phone])

        await coordinator.reloadDevices()

        #expect(coordinator.selectedDeviceID == nil)
        #expect(coordinator.actionLog.isEmpty)
        #expect(Set(coordinator.actionHistoryByDeviceID.keys) == ["phone"])
        #expect(coordinator.requiresExplicitDeviceSelection)
        #expect(coordinator.failure?.code == "simulator_saved_device_unavailable")
    }

    @Test("Device unavailability clears stale rendering state")
    func deviceUnavailableClearsRenderingState() async {
        let client = SimulatorPaneClientSpy(devices: [
            Self.device(id: "phone", family: .iPhone, state: .booted),
        ])
        let coordinator = SimulatorPaneCoordinator(client: client)
        await coordinator.start()
        await client.emit(.message(.frameTransport(simulatorFrameTransportDescriptor(42))))
        await client.emit(.message(.display(SimulatorDisplayMetadata(
            width: 1_200,
            height: 2_400,
            orientation: .portrait,
            scale: 3
        ))))
        await client.emit(.message(.capabilities([.framebuffer, .touch])))
        await client.emit(.message(.status(.deviceUnavailable)))
        await eventually { coordinator.status == .deviceUnavailable }

        #expect(coordinator.frameTransport == nil)
        #expect(coordinator.display == nil)
        #expect(coordinator.capabilities == [.userInterfaceSettings])
    }

    @Test("A stale frame mapping failure cannot invalidate its replacement")
    func staleFrameMappingFailureIsIgnored() async {
        let client = SimulatorPaneClientSpy(devices: [])
        let coordinator = SimulatorPaneCoordinator(client: client)
        let staleTransport = simulatorFrameTransportDescriptor(51)
        let replacementTransport = simulatorFrameTransportDescriptor(52)
        let failure = SimulatorFailure(
            code: "framebuffer_unavailable",
            message: "The stale frame ring is unavailable.",
            isRecoverable: true
        )
        coordinator.frameTransport = replacementTransport

        coordinator.receiveFrameTransportFailure(failure, for: staleTransport)
        await Task.yield()

        #expect(coordinator.frameTransport == replacementTransport)
        #expect(coordinator.failure == nil)
        #expect(await client.invalidationCount() == 0)
    }

    @Test("Frame mapping cleanup finishes before a replacement worker activates")
    func frameMappingCleanupPrecedesReplacementActivation() async {
        let device = Self.device(id: "phone", family: .iPhone, state: .booted)
        let client = SimulatorPaneClientSpy(
            devices: [device],
            delaysInvalidation: true
        )
        let coordinator = SimulatorPaneCoordinator(client: client)
        coordinator.devices = [device]
        coordinator.frameTransport = simulatorFrameTransportDescriptor(61)
        let failure = SimulatorFailure(
            code: "framebuffer_unavailable",
            message: "The frame ring cannot be mapped.",
            isRecoverable: true
        )

        coordinator.receiveFrameTransportFailure(
            failure,
            for: simulatorFrameTransportDescriptor(61)
        )
        coordinator.selectDevice(id: device.id)
        await eventually { await client.hasDelayedInvalidation() }

        #expect(await client.activations().isEmpty)

        await client.resumeInvalidation()
        await eventually { await client.activations().count == 1 }

        #expect(await client.activations().map(\.id) == [device.id])
    }

    @Test("Selecting another device clears every device-scoped tool value")
    func selectionClearsDeviceScopedState() async {
        let application = Self.application(id: "com.example.old", type: "User")
        let client = SimulatorPaneClientSpy(devices: [
            Self.device(id: "one", family: .iPhone, state: .booted),
            Self.device(id: "two", family: .iPad, state: .booted),
        ])
        let coordinator = SimulatorPaneCoordinator(client: client)
        await coordinator.start()
        let display = SimulatorDisplayMetadata(
            width: 1_200,
            height: 2_400,
            orientation: .portrait,
            scale: 3
        )
        coordinator.display = display
        coordinator.frameTransport = simulatorFrameTransportDescriptor(42)
        coordinator.failure = SimulatorFailure(code: "old", message: "old", isRecoverable: true)
        coordinator.controlFailure = SimulatorFailure(code: "tool", message: "old", isRecoverable: true)
        coordinator.installedApplications = [application]
        coordinator.userInstalledApplications = [application]
        coordinator.clipboardText = "old clipboard"
        coordinator.recentLogsText = "old recent logs"
        coordinator.liveLogsText = "old live logs"
        coordinator.foregroundApplication = SimulatorApplicationInfo(
            bundleIdentifier: application.id,
            processIdentifier: 7,
            name: application.displayName,
            version: "1",
            build: "1",
            minimumOSVersion: "26.0",
            isReactNative: false
        )
        coordinator.accessibilitySnapshot = SimulatorAccessibilitySnapshot(roots: [], display: display)
        coordinator.highlightedAccessibilityNodeID = "old-node"
        coordinator.privacySnapshot = SimulatorPrivacySnapshot(
            deviceID: "one",
            bundleIdentifier: application.id,
            authorizations: [:]
        )
        coordinator.interfaceStatus = SimulatorInterfaceStatus(
            liquidGlass: .tinted,
            colorFilter: .grayscale,
            reduceMotion: true,
            buttonShapes: true,
            reduceTransparency: true,
            voiceOver: true
        )
        coordinator.cameraConfiguration = .placeholder
        coordinator.cameraStatus = SimulatorCameraStatus(
            configuration: .placeholder,
            mirrorMode: .auto,
            injectedBundleIdentifiers: [application.id],
            hostCameras: []
        )
        coordinator.locationRouteIsActive = true
        coordinator.locationRouteIsPaused = true
        coordinator.isVideoRecording = true
        coordinator.isStreamingLogs = true
        coordinator.actionLog = [SimulatorActionLogEntry(
            id: UUID(),
            timestamp: Date(),
            action: "old",
            summary: "old",
            succeeded: true
        )]

        coordinator.selectDevice(id: "two")

        #expect(coordinator.selectedDeviceID == "two")
        #expect(coordinator.display == nil)
        #expect(coordinator.frameTransport == nil)
        #expect(coordinator.failure == nil)
        #expect(coordinator.controlFailure == nil)
        #expect(coordinator.installedApplications.isEmpty)
        #expect(coordinator.userInstalledApplications.isEmpty)
        #expect(coordinator.clipboardText.isEmpty)
        #expect(coordinator.recentLogsText.isEmpty)
        #expect(coordinator.liveLogsText.isEmpty)
        #expect(coordinator.foregroundApplication == nil)
        #expect(coordinator.accessibilitySnapshot == nil)
        #expect(coordinator.highlightedAccessibilityNodeID == nil)
        #expect(coordinator.privacySnapshot == nil)
        #expect(coordinator.interfaceStatus == nil)
        #expect(coordinator.cameraStatus == nil)
        #expect(coordinator.cameraConfiguration == .disabled)
        #expect(coordinator.locationRouteIsActive == false)
        #expect(coordinator.locationRouteIsPaused == false)
        #expect(coordinator.isVideoRecording == false)
        #expect(coordinator.isStreamingLogs == false)
        #expect(coordinator.actionLog.isEmpty)
    }

    @Test("A delayed control result cannot overwrite the newly selected device")
    func delayedOldControlResultIsDiscarded() async {
        let oldApplication = Self.application(id: "com.example.old", type: "User")
        let client = SimulatorPaneClientSpy(
            devices: [
                Self.device(id: "one", family: .iPhone, state: .booted),
                Self.device(id: "two", family: .iPad, state: .booted),
            ],
            delaysApplicationList: true
        )
        let coordinator = SimulatorPaneCoordinator(client: client)
        await coordinator.start()

        let oldRequest = Task { await coordinator.refreshApplications() }
        await eventually { await client.hasDelayedApplicationList() }
        coordinator.selectDevice(id: "two")
        await client.resumeApplicationList(with: [oldApplication])
        await oldRequest.value

        #expect(coordinator.selectedDeviceID == "two")
        #expect(coordinator.installedApplications.isEmpty)
        #expect(coordinator.userInstalledApplications.isEmpty)
        #expect(coordinator.controlFailure == nil)
    }
}
