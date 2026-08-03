import AppKit
import CmuxSimulator
import Testing
@testable import CmuxSimulatorUI

@Suite("Simulator tool device scoping")
@MainActor
struct SimulatorToolDeviceSwitchTests {
    @Test("Appearance rehydrates when the selected device changes")
    func appearanceRehydratesOnDeviceChange() async {
        let client = SimulatorPaneClientSpy(devices: [])
        let coordinator = SimulatorPaneCoordinator(client: client)
        coordinator.selectedDeviceID = "one"
        let view = host(SimulatorAppearanceTools(coordinator: coordinator))

        #expect(await eventually {
            await client.actions().contains(.readInterfaceStatus(deviceID: "one"))
        })

        coordinator.selectedDeviceID = "two"
        view.update()

        #expect(await eventually {
            await client.actions().contains(.readInterfaceStatus(deviceID: "two"))
        })
        withExtendedLifetime(view) {}
    }

    @Test("Notification and privacy tools re-adopt state after a device change")
    func notificationPrivacyRehydratesOnDeviceChange() async {
        let client = SimulatorPaneClientSpy(devices: [])
        let coordinator = SimulatorPaneCoordinator(client: client)
        coordinator.capabilities = [.foregroundApplication]
        coordinator.selectedDeviceID = "one"
        let view = host(SimulatorNotificationPrivacyTools(coordinator: coordinator))

        #expect(await eventually {
            await client.actions().filter { $0 == .readForegroundApplication }.count == 1
        })

        coordinator.selectedDeviceID = "two"
        view.update()

        #expect(await eventually {
            await client.actions().filter { $0 == .readForegroundApplication }.count == 2
        })
        withExtendedLifetime(view) {}
    }

    @Test("Camera tools rehydrate when the selected device changes")
    func cameraRehydratesOnDeviceChange() async {
        let client = SimulatorPaneClientSpy(devices: [])
        let coordinator = SimulatorPaneCoordinator(client: client)
        coordinator.selectedDeviceID = "one"
        let view = host(SimulatorCameraTools(coordinator: coordinator))

        #expect(await eventually {
            await client.actions().filter { $0 == .readCameraStatus }.count == 1
        })

        coordinator.selectedDeviceID = "two"
        view.update()

        #expect(await eventually {
            await client.actions().filter { $0 == .readCameraStatus }.count == 2
        })
        withExtendedLifetime(view) {}
    }

    @Test("Camera target falls back when its app leaves the inventory")
    func cameraTargetFollowsInventory() {
        let applications = [application(id: "com.example.new", name: "New")]

        #expect(simulatorCameraTargetBundleIdentifier(
            current: "com.example.old",
            applications: applications
        ).isEmpty)
        #expect(simulatorCameraTargetBundleIdentifier(
            current: "com.example.new",
            applications: applications
        ) == "com.example.new")
    }

    private func host<View: NSView & SimulatorToolsSection>(_ view: View) -> View {
        view.frame = NSRect(x: 0, y: 0, width: 480, height: 900)
        view.update()
        view.layoutSubtreeIfNeeded()
        return view
    }

    private func application(id: String, name: String) -> SimulatorInstalledApplication {
        SimulatorInstalledApplication(
            id: id,
            name: name,
            displayName: name,
            executableName: name,
            path: "/Applications/\(name).app",
            applicationType: "User"
        )
    }

    private func eventually(
        _ condition: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        for _ in 0..<100 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}
