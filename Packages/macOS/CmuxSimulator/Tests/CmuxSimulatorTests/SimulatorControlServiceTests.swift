import CmuxFoundation
import Foundation
import Testing
@testable import CmuxSimulator

@Suite("Simulator control service")
struct SimulatorControlServiceTests {
    @Test("Outer operation deadlines cover their nested command budgets")
    func outerOperationDeadlinesCoverNestedBudgets() {
        let deadlines = SimulatorOperationDeadlines()

        #expect(deadlines.selectDevice >= 543)
        #expect(deadlines.recover >= 483)
        #expect(deadlines.textInputReadiness >= deadlines.selectDevice)
        #expect(deadlines.clientTimeout(for: deadlines.inspectionRead) == 45)
        #expect(SimulatorOperationDeadlines(selectDevice: 600).textInputReadiness == 600)
    }

    @Test("Device discovery maps runtime names, state, family, and boot date")
    func discoversDevices() async throws {
        let commands = RecordingCommandRunner(results: [
            .success(#"{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-26-5":[{"udid":"DEVICE","name":"iPhone 17 Pro","state":"Booted","isAvailable":true,"deviceTypeIdentifier":"com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro","lastBootedAt":"2026-07-09T12:00:00Z"}]}}"#),
            .success(#"{"runtimes":[{"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-26-5","name":"iOS 26.5","supportedDeviceTypes":[{"identifier":"com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro","productFamily":"iPhone"}]}]}"#),
        ])
        let service = SimulatorControlService(commands: commands)

        let devices = try await service.discoverDevices()

        #expect(devices.count == 1)
        #expect(devices[0].id == "DEVICE")
        #expect(devices[0].runtimeName == "iOS 26.5")
        #expect(devices[0].family == .iPhone)
        #expect(devices[0].state == .booted)
        #expect(devices[0].lastBootedAt != nil)
        let invocations = await commands.recordedInvocations()
        #expect(invocations.map(\.arguments) == [
            ["simctl", "list", "devices", "--json"],
            ["simctl", "list", "runtimes", "--json"],
        ])
    }

    @Test("Application listing parses the OpenStep property list")
    func listsApplications() async throws {
        let commands = RecordingCommandRunner(results: [.success("""
        {
            "com.example.app" = {
                ApplicationType = User;
                CFBundleDisplayName = "Example App";
                CFBundleExecutable = Example;
                CFBundleIdentifier = "com.example.app";
                CFBundleName = Example;
                Path = "/tmp/Example.app";
            };
        }
        """)])
        let service = SimulatorControlService(commands: commands)

        let applications = try await service.listApplications(deviceID: "DEVICE")

        #expect(applications == [SimulatorInstalledApplication(
            id: "com.example.app",
            name: "Example",
            displayName: "Example App",
            executableName: "Example",
            path: "/tmp/Example.app",
            applicationType: "User"
        )])
    }

    @Test("Camera cleanup propagates a clean relaunch failure")
    func cameraCleanupPropagatesRelaunchFailure() async throws {
        let deviceIdentifier = "DEVICE-\(UUID().uuidString)"
        let bundleIdentifier = "com.example.camera"
        let ownershipScope = SimulatorCameraCleanupOwnershipScope()
        let ownershipToken = try await ownershipScope.coordinator.claim(
            deviceIdentifier: deviceIdentifier,
            bundleIdentifier: bundleIdentifier
        )
        let commands = RecordingCommandRunner(results: [
            .success(""),
            .failure("relaunch failed"),
        ])
        let service = SimulatorControlService(
            commands: commands,
            cameraCleanupOwnershipScope: ownershipScope
        )

        do {
            try await service.cleanupCameraApplication(
                deviceID: deviceIdentifier,
                bundleIdentifier: bundleIdentifier,
                ownershipToken: ownershipToken
            )
            Issue.record("Expected the clean relaunch failure")
        } catch let error as SimulatorControlError {
            #expect(error.message.contains("relaunch failed"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Device type identifies family when runtimes omit family metadata")
    func handlesDuplicateRuntimeIdentifiers() async throws {
        let commands = RecordingCommandRunner(results: [
            .success(#"{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-26-4":[{"udid":"DEVICE","name":"iPhone 17","state":"Shutdown","isAvailable":true,"deviceTypeIdentifier":"com.apple.CoreSimulator.SimDeviceType.iPhone-17"}]}}"#),
            .success(#"{"runtimes":[{"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-26-4","name":"iOS 26.4","version":"26.4","isAvailable":true},{"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-26-4","name":"iOS 26.4.1","version":"26.4.1","isAvailable":true}]}"#),
        ])
        let service = SimulatorControlService(commands: commands)

        let devices = try await service.discoverDevices()

        #expect(devices.first?.runtimeName == "iOS 26.4.1")
        #expect(devices.first?.family == .iPhone)
    }

    @Test("Missing structured family metadata never trusts the device name")
    func missingFamilyMetadataFailsClosed() async throws {
        let commands = RecordingCommandRunner(results: [
            .success(#"{"devices":{"com.apple.CoreSimulator.SimRuntime.tvOS-26-0":[{"udid":"TV","name":"iPhone Test","state":"Booted","isAvailable":true,"deviceTypeIdentifier":"com.apple.CoreSimulator.SimDeviceType.Apple-TV"}]}}"#),
            .success(#"{"runtimes":[{"identifier":"com.apple.CoreSimulator.SimRuntime.tvOS-26-0","name":"tvOS 26.0"}]}"#),
        ])
        let service = SimulatorControlService(commands: commands)

        let devices = try await service.discoverDevices()

        #expect(devices.first?.family == .television)
    }

    @Test("Routes project validated speed, cadence, and waypoints without shell interpolation")
    func startsLocationRoute() async throws {
        let commands = RecordingCommandRunner()
        let service = SimulatorControlService(commands: commands)
        let route = SimulatorLocationRoute(
            waypoints: [
                SimulatorLocationCoordinate(latitude: 37.7, longitude: -122.4),
                SimulatorLocationCoordinate(latitude: 37.8, longitude: -122.3),
            ],
            speed: 4.5,
            updateDistance: 10,
            updateInterval: 2
        )

        try await service.startLocationRoute(deviceID: "DEVICE", route: route)

        let invocation = try #require(await commands.recordedInvocations().first)
        #expect(invocation.executable == "/usr/bin/xcrun")
        #expect(invocation.arguments == [
            "simctl", "location", "DEVICE", "start", "--speed=4.5",
            "--distance=10.0", "--interval=2.0", "37.7,-122.4", "37.8,-122.3",
        ])
    }

    @Test("Looping routes close their path and rotate pause progress")
    func loopingLocationRoute() async throws {
        let commands = RecordingCommandRunner()
        let service = SimulatorControlService(
            commands: commands,
            routeSleep: { _ in try await ContinuousClock().sleep(for: .seconds(3_600)) }
        )
        let route = SimulatorLocationRoute(
            waypoints: [
                SimulatorLocationCoordinate(latitude: 0, longitude: 0),
                SimulatorLocationCoordinate(latitude: 0, longitude: 0.01),
                SimulatorLocationCoordinate(latitude: 0.01, longitude: 0.01),
            ],
            speed: 10,
            loops: true
        )

        try await service.startLocationRoute(deviceID: "DEVICE", route: route)

        let arguments = try #require(await commands.recordedInvocations().first?.arguments)
        #expect(arguments.suffix(4) == [
            "0.0,0.0", "0.0,0.01", "0.01,0.01", "0.0,0.0",
        ])
        let remaining = await service.remainingRoute(route, after: 120)
        #expect(remaining.loops)
        #expect(remaining.waypoints.count == 4)
        #expect(remaining.waypoints.first != route.waypoints.first)
        try await service.stopLocationRoute(deviceID: "DEVICE")
    }

    @Test("Private permission catalog entries fail explicitly without mutating stores")
    func rejectsHostPrivatePermissionMutation() async {
        let commands = RecordingCommandRunner()
        let service = SimulatorControlService(commands: commands)

        do {
            try await service.setPrivacy(
                deviceID: "DEVICE",
                action: .grant,
                service: .criticalNotifications,
                bundleIdentifier: "com.example.app"
            )
            Issue.record("Expected a typed unsupported failure")
        } catch let error as SimulatorControlError {
            #expect(error.code == "unsupported_private_permission")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(await commands.recordedInvocations().isEmpty)
    }

    @Test("Pause freezes an estimated route position and resume continues the remainder")
    func pausesAndResumesLocationRoute() async throws {
        let commands = RecordingCommandRunner()
        let clock = TestNow(Date(timeIntervalSince1970: 1_000))
        let service = SimulatorControlService(commands: commands, now: { clock.value })
        let route = SimulatorLocationRoute(
            waypoints: [
                SimulatorLocationCoordinate(latitude: 0, longitude: 0),
                SimulatorLocationCoordinate(latitude: 0, longitude: 0.01),
            ],
            speed: 100
        )
        try await service.startLocationRoute(deviceID: "DEVICE", route: route)
        clock.advance(by: 5)

        try await service.pauseLocationRoute(deviceID: "DEVICE")
        let pausedArguments = await commands.recordedInvocations().map(\.arguments)
        #expect(pausedArguments[1] == ["simctl", "location", "DEVICE", "clear"])
        #expect(pausedArguments[2].prefix(4) == ["simctl", "location", "DEVICE", "set"])
        let frozen = try #require(pausedArguments[2].last)
        let frozenLongitude = try #require(Double(frozen.split(separator: ",")[1]))
        #expect(frozenLongitude > 0)
        #expect(frozenLongitude < 0.01)

        try await service.resumeLocationRoute(deviceID: "DEVICE")
        let resumed = try #require(await commands.recordedInvocations().last?.arguments)
        #expect(resumed.prefix(4) == ["simctl", "location", "DEVICE", "start"])
        #expect(resumed.last == "0.0,0.01")
    }

    @Test("A failed route clear preserves the running route for retry")
    func failedPausePreservesRunningRoute() async throws {
        let commands = RecordingCommandRunner(results: [
            .success(""),
            .failure("clear failed"),
            .success(""),
            .success(""),
        ])
        let service = SimulatorControlService(commands: commands)
        let route = SimulatorLocationRoute(
            waypoints: [
                SimulatorLocationCoordinate(latitude: 0, longitude: 0),
                SimulatorLocationCoordinate(latitude: 0, longitude: 0.01),
            ],
            speed: 100
        )
        try await service.startLocationRoute(deviceID: "DEVICE", route: route)

        await #expect(throws: SimulatorControlError.self) {
            try await service.pauseLocationRoute(deviceID: "DEVICE")
        }
        try await service.pauseLocationRoute(deviceID: "DEVICE")

        let invocations = await commands.recordedInvocations().map(\.arguments)
        #expect(invocations[1] == ["simctl", "location", "DEVICE", "clear"])
        #expect(invocations[2] == ["simctl", "location", "DEVICE", "clear"])
        #expect(invocations[3].prefix(4) == ["simctl", "location", "DEVICE", "set"])
    }

    @Test("Accessibility-helper interface settings stay out of the host service")
    func rejectsWorkerOwnedInterfaceSettings() async throws {
        let commands = RecordingCommandRunner()
        let service = SimulatorControlService(commands: commands)

        await #expect(throws: SimulatorControlError.self) {
            try await service.setInterface(deviceID: "DEVICE", setting: .colorFilter(.greenRed))
        }

        #expect(await commands.recordedInvocations().isEmpty)
    }

    @Test("Relative text-size changes use the typed simctl UI action")
    func adjustsContentSize() async throws {
        let commands = RecordingCommandRunner()
        let service = SimulatorControlService(commands: commands)

        try await service.setInterface(
            deviceID: "DEVICE",
            setting: .contentSizeAdjustment(.increment)
        )

        #expect(await commands.recordedInvocations().map(\.arguments) == [[
            "simctl", "ui", "DEVICE", "content_size", "increment",
        ]])
    }

    @Test("Private permission catalog stays out of public simctl privacy")
    func rejectsPrivatePrivacyServices() async throws {
        let commands = RecordingCommandRunner()
        let service = SimulatorControlService(commands: commands)
        let privateServices: [SimulatorPrivacyService] = [
            .photosLimited, .camera, .notifications, .criticalNotifications, .speech,
            .faceID, .userTracking, .homeKit,
        ]

        for privacyService in privateServices {
            await #expect(throws: SimulatorControlError.self) {
                try await service.setPrivacy(
                    deviceID: "DEVICE",
                    action: .grant,
                    service: privacyService,
                    bundleIdentifier: "com.example.app"
                )
            }
        }

        #expect(await commands.recordedInvocations().isEmpty)
    }

    @Test("Clipboard staging is owner-only and removed after pbcopy")
    func stagesClipboardPrivately() async throws {
        let commands = ClipboardInspectingCommandRunner()
        let service = SimulatorControlService(commands: commands)

        try await service.setClipboardText("secret 🥖", deviceID: "DEVICE")

        let observation = try #require(await commands.observation)
        #expect(observation.text == "secret 🥖")
        #expect(observation.permissions & 0o777 == 0o600)
        #expect(!FileManager.default.fileExists(atPath: observation.path))
    }

    @Test("Pasteboard sync names host as the source and device as destination")
    func syncsClipboardFromHost() async throws {
        let commands = RecordingCommandRunner()
        let service = SimulatorControlService(commands: commands)

        try await service.syncClipboardFromHost(deviceID: "DEVICE")

        #expect(await commands.recordedInvocations().first?.arguments == [
            "simctl", "pbsync", "host", "DEVICE",
        ])
    }

    @Test("Video and log descriptors remain argv-based and cancellable by their owner")
    func createsLongRunningDescriptors() async {
        let service = SimulatorControlService(commands: RecordingCommandRunner())
        let video = service.videoRecordingCommand(
            deviceID: "DEVICE",
            destinationURL: URL(fileURLWithPath: "/tmp/movie.mov"),
            codec: .h264
        )
        let logs = service.logStreamCommand(deviceID: "DEVICE", bundleIdentifier: "com.example.app")

        #expect(video.executable == "/usr/bin/xcrun")
        #expect(video.arguments == [
            "simctl", "io", "DEVICE", "recordVideo", "--codec=h264", "--force", "/tmp/movie.mov",
        ])
        #expect(logs.arguments.suffix(2) == ["--predicate", "subsystem == \"com.example.app\""])
    }

    @Test("Recent logs append a clear marker after bounded capture truncates")
    func truncatesRecentLogs() async throws {
        let commands = RecordingCommandRunner(results: [
            .success(String(repeating: "x", count: SimulatorControlService.maximumRecentLogBytes + 1)),
        ])
        let service = SimulatorControlService(commands: commands)

        let logs = try await service.recentLogs(deviceID: "DEVICE")
        let marker = String(
            localized: "simulator.logs.outputTruncated",
            defaultValue: "Output truncated at 2 MiB."
        )

        #expect(logs.utf8.count < SimulatorControlService.maximumRecentLogBytes + 100)
        #expect(logs.contains("[\(marker)]"))
    }

    @Test("Oversized clipboard capture fails instead of exposing a partial value")
    func rejectsOversizedClipboard() async {
        let commands = RecordingCommandRunner(results: [
            .success(String(repeating: "x", count: SimulatorControlService.maximumClipboardBytes + 1)),
        ])
        let service = SimulatorControlService(commands: commands)

        do {
            _ = try await service.clipboardText(deviceID: "DEVICE")
            Issue.record("Expected oversized clipboard failure")
        } catch let error as SimulatorControlError {
            #expect(error.code == "clipboard_output_too_large")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Oversized clipboard writes fail before staging or subprocess launch")
    func rejectsOversizedClipboardWrite() async {
        let commands = RecordingCommandRunner()
        let service = SimulatorControlService(commands: commands)

        do {
            try await service.setClipboardText(
                String(repeating: "x", count: SimulatorControlService.maximumClipboardBytes + 1),
                deviceID: "DEVICE"
            )
            Issue.record("Expected oversized clipboard input failure")
        } catch let error as SimulatorControlError {
            #expect(error.code == "clipboard_input_too_large")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(await commands.recordedInvocations().isEmpty)
    }

    @Test("Oversized device discovery is capped before JSON decoding")
    func capsDeviceDiscovery() async {
        let oversized = #"{"devices":{"runtime":[{"udid":"DEVICE","name":""#
            + String(repeating: "x", count: SimulatorControlService.maximumInventoryBytes)
            + #"","state":"Booted"}]}}"#
        let commands = RecordingCommandRunner(results: [.success(oversized)])
        let service = SimulatorControlService(commands: commands)

        await #expect(throws: (any Error).self) {
            try await service.discoverDevices()
        }
        #expect(await commands.recordedBoundedLimits().first?.output
            == SimulatorControlService.maximumInventoryBytes)
    }

    @Test("Oversized app inventory is capped before property-list decoding")
    func capsApplicationInventory() async {
        let oversized = """
        { "com.example.app" = { ApplicationType = User; CFBundleDisplayName = "
        """ + String(repeating: "x", count: SimulatorControlService.maximumInventoryBytes) + """
        "; CFBundleIdentifier = "com.example.app"; Path = "/tmp/App.app"; }; }
        """
        let commands = RecordingCommandRunner(results: [.success(oversized)])
        let service = SimulatorControlService(commands: commands)

        await #expect(throws: (any Error).self) {
            try await service.listApplications(deviceID: "DEVICE")
        }
        #expect(await commands.recordedBoundedLimits().first?.output
            == SimulatorControlService.maximumInventoryBytes)
    }

    @Test("Mutation diagnostics keep only the small bounded output class")
    func capsMutationOutput() async throws {
        let commands = RecordingCommandRunner(results: [
            .success(String(repeating: "x", count: SimulatorControlService.maximumMutationOutputBytes + 1)),
        ])
        let service = SimulatorControlService(commands: commands)

        try await service.terminateApplication(
            deviceID: "DEVICE",
            bundleIdentifier: "com.example.app"
        )

        #expect(await commands.recordedBoundedLimits().first?.output
            == SimulatorControlService.maximumMutationOutputBytes)
    }

    @Test("Application launch secrets stay in the child environment")
    func launchEnvironmentIsNotExposedInArguments() async throws {
        let commands = RecordingCommandRunner(results: [.success("com.example.app: 42")])
        let service = SimulatorControlService(commands: commands)

        _ = try await service.launchApplication(
            deviceID: "DEVICE",
            bundleIdentifier: "com.example.app",
            configuration: SimulatorLaunchConfiguration(environment: ["API_TOKEN": "top-secret"])
        )

        let invocation = try #require(await commands.recordedInvocations().first)
        #expect(invocation.executable == "/usr/bin/xcrun")
        #expect(invocation.arguments == ["simctl", "launch", "DEVICE", "com.example.app"])
        #expect(!invocation.arguments.joined(separator: " ").contains("top-secret"))
        #expect(invocation.environment == ["SIMCTL_CHILD_API_TOKEN": "top-secret"])
    }
}

private extension CommandResult {
    static func success(_ stdout: String) -> CommandResult {
        CommandResult(stdout: stdout, stderr: "", exitStatus: 0, timedOut: false, executionError: nil)
    }

    static func failure(_ stderr: String) -> CommandResult {
        CommandResult(stdout: "", stderr: stderr, exitStatus: 1, timedOut: false, executionError: nil)
    }
}
