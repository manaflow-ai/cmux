import CmuxSimulator
import Foundation
import Testing
@testable import CmuxSimulatorUI

@MainActor
extension SimulatorPaneCoordinatorTests {
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
            await client.emit(.message(.actionLog(SimulatorActionLogEntry(
                id: UUID(),
                timestamp: Date(timeIntervalSince1970: TimeInterval(index)),
                action: "worker-\(index)",
                summary: "worker-\(index)",
                succeeded: true
            ))))
        }
        await eventually { coordinator.actionLog.first?.action == "worker-524" }

        #expect(coordinator.actionLog.count == 500)
        #expect(coordinator.actionLog.last?.action == "worker-25")
    }

    @Test("Device unavailability clears stale rendering state")
    func deviceUnavailableClearsRenderingState() async {
        let client = SimulatorPaneClientSpy(devices: [
            Self.device(id: "phone", family: .iPhone, state: .booted),
        ])
        let coordinator = SimulatorPaneCoordinator(client: client)
        await coordinator.start()
        await client.emit(.message(.context(42)))
        await client.emit(.message(.display(SimulatorDisplayMetadata(
            width: 1_200,
            height: 2_400,
            orientation: .portrait,
            scale: 3
        ))))
        await client.emit(.message(.capabilities([.framebuffer, .touch])))
        await client.emit(.message(.status(.deviceUnavailable)))
        await eventually { coordinator.status == .deviceUnavailable }

        #expect(coordinator.contextID == nil)
        #expect(coordinator.display == nil)
        #expect(coordinator.capabilities == [.userInterfaceSettings])
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
        coordinator.contextID = 42
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
        #expect(coordinator.contextID == nil)
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
