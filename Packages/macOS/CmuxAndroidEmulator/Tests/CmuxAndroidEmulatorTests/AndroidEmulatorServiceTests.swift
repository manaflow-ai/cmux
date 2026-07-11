@testable import CmuxAndroidEmulator
import CmuxFoundation
import Foundation
import Testing

@Suite struct AndroidEmulatorServiceTests {
    @Test func snapshotMapsConnectedSerialToInstalledAVD() async throws {
        let installation = Self.installation
        let commands = StubCommandRunner(results: [
            StubCommand(
                executable: installation.emulatorURL.path,
                arguments: ["-list-avds"]
            ): .success("Tablet_API_35\nPixel_9_API_35\nPixel_9_API_35\n"),
            StubCommand(
                executable: installation.adbURL!.path,
                arguments: ["devices", "-l"]
            ): .success("List of devices attached\nemulator-5554\tdevice transport_id:42\nphysical-1\tdevice\n"),
            StubCommand(
                executable: installation.adbURL!.path,
                arguments: ["-s", "emulator-5554", "emu", "avd", "name"]
            ): .success("Pixel_9_API_35\nOK\n"),
        ])
        let service = AndroidEmulatorService(
            sdkLocator: StubSDKLocator(resolution: .available(installation)),
            commands: commands,
            processLauncher: RecordingAndroidEmulatorLauncher()
        )

        let snapshot = try await service.snapshot()

        #expect(snapshot.sdkRootURL == installation.rootURL)
        #expect(snapshot.warning == nil)
        #expect(snapshot.devices.map(\.name) == ["Pixel_9_API_35", "Tablet_API_35"])
        #expect(snapshot.devices[0].state == .running(
            serial: "emulator-5554",
            connectionState: "device",
            transportID: "42"
        ))
        #expect(snapshot.devices[1].state == .stopped)
    }

    @Test func missingADBMarksAVDStateUnavailable() async throws {
        let installation = AndroidSDKInstallation(
            rootURL: Self.installation.rootURL,
            emulatorURL: Self.installation.emulatorURL,
            adbURL: nil
        )
        let commands = StubCommandRunner(results: [
            StubCommand(
                executable: installation.emulatorURL.path,
                arguments: ["-list-avds"]
            ): .success("Pixel_9_API_35\n"),
        ])
        let service = AndroidEmulatorService(
            sdkLocator: StubSDKLocator(resolution: .available(installation)),
            commands: commands,
            processLauncher: RecordingAndroidEmulatorLauncher()
        )

        let snapshot = try await service.snapshot()

        #expect(snapshot.warning == .adbMissing)
        #expect(snapshot.devices == [AndroidVirtualDevice(name: "Pixel_9_API_35", state: .unavailable)])
    }

    @Test func launchValidatesNameAndUsesVendorExecutable() async throws {
        let installation = Self.installation
        let launcher = RecordingAndroidEmulatorLauncher()
        let commands = StubCommandRunner(results: [
            StubCommand(
                executable: installation.emulatorURL.path,
                arguments: ["-list-avds"]
            ): .success("Pixel_9_API_35\n"),
            StubCommand(
                executable: installation.adbURL!.path,
                arguments: ["devices"]
            ): .success("List of devices attached\n"),
            StubCommand(
                executable: installation.adbURL!.path,
                arguments: ["-s", "emulator-5554", "wait-for-device"]
            ): .success(""),
            StubCommand(
                executable: installation.adbURL!.path,
                arguments: ["-s", "emulator-5554", "emu", "avd", "name"]
            ): .success("Pixel_9_API_35\nOK\n"),
        ])
        let service = AndroidEmulatorService(
            sdkLocator: StubSDKLocator(resolution: .available(installation)),
            commands: commands,
            processLauncher: launcher
        )

        try await service.launch(avdName: "Pixel_9_API_35")

        #expect(await launcher.requests == [LaunchRequest(
            executableURL: installation.emulatorURL,
            avdName: "Pixel_9_API_35",
            sdkRootURL: installation.rootURL,
            consolePort: 5554
        )])
    }

    @Test func launchSkipsConsolePairWithOccupiedAdjacentPort() async throws {
        let installation = Self.installation
        let launcher = RecordingAndroidEmulatorLauncher(unavailableConsolePorts: [5555])
        let commands = StubCommandRunner(results: [
            StubCommand(
                executable: installation.emulatorURL.path,
                arguments: ["-list-avds"]
            ): .success("Pixel_9_API_35\n"),
            StubCommand(
                executable: installation.adbURL!.path,
                arguments: ["devices"]
            ): .success("List of devices attached\n"),
            StubCommand(
                executable: installation.adbURL!.path,
                arguments: ["-s", "emulator-5556", "wait-for-device"]
            ): .success(""),
            StubCommand(
                executable: installation.adbURL!.path,
                arguments: ["-s", "emulator-5556", "emu", "avd", "name"]
            ): .success("Pixel_9_API_35\nOK\n"),
        ])
        let service = AndroidEmulatorService(
            sdkLocator: StubSDKLocator(resolution: .available(installation)),
            commands: commands,
            processLauncher: launcher
        )

        try await service.launch(avdName: "Pixel_9_API_35")

        #expect(await launcher.requests.map(\.consolePort) == [5556])
    }

    @Test func snapshotRejectsConsoleErrorReturnedWithZeroExitStatus() async throws {
        let installation = Self.installation
        let commands = StubCommandRunner(results: [
            StubCommand(
                executable: installation.emulatorURL.path,
                arguments: ["-list-avds"]
            ): .success("Pixel_9_API_35\n"),
            StubCommand(
                executable: installation.adbURL!.path,
                arguments: ["devices", "-l"]
            ): .success("List of devices attached\nemulator-5554\tdevice transport_id:42\n"),
            StubCommand(
                executable: installation.adbURL!.path,
                arguments: ["-s", "emulator-5554", "emu", "avd", "name"]
            ): .success("KO: 'avd name' is currently unsupported\nOK\n"),
        ])
        let service = AndroidEmulatorService(
            sdkLocator: StubSDKLocator(resolution: .available(installation)),
            commands: commands,
            processLauncher: RecordingAndroidEmulatorLauncher()
        )

        let snapshot = try await service.snapshot()

        #expect(snapshot.devices == [AndroidVirtualDevice(name: "Pixel_9_API_35", state: .unavailable)])
        #expect(snapshot.warning != nil)
    }

    @Test func failedLaunchConfirmationTerminatesSpawnedProcess() async {
        let installation = Self.installation
        let launcher = RecordingAndroidEmulatorLauncher()
        let commands = StubCommandRunner(results: [
            StubCommand(
                executable: installation.emulatorURL.path,
                arguments: ["-list-avds"]
            ): .success("Pixel_9_API_35\n"),
            StubCommand(
                executable: installation.adbURL!.path,
                arguments: ["devices"]
            ): .success("List of devices attached\n"),
            StubCommand(
                executable: installation.adbURL!.path,
                arguments: ["-s", "emulator-5554", "wait-for-device"]
            ): CommandResult(
                stdout: nil,
                stderr: nil,
                exitStatus: nil,
                timedOut: true,
                executionError: nil
            ),
        ])
        let service = AndroidEmulatorService(
            sdkLocator: StubSDKLocator(resolution: .available(installation)),
            commands: commands,
            processLauncher: launcher
        )

        await #expect(throws: AndroidEmulatorError.launchNotConfirmed(name: "Pixel_9_API_35")) {
            try await service.launch(avdName: "Pixel_9_API_35")
        }

        #expect(await launcher.terminatedProcessIDs == [RecordingAndroidEmulatorLauncher.processID])
    }

    @Test func concurrentLaunchesReserveDistinctConsolePorts() async {
        let commands = ConcurrentLaunchCommandRunner(installation: Self.installation)
        let launcher = RecordingAndroidEmulatorLauncher()
        let service = AndroidEmulatorService(
            sdkLocator: StubSDKLocator(resolution: .available(Self.installation)),
            commands: commands,
            processLauncher: launcher
        )

        let pixelLaunch = Task { try? await service.launch(avdName: "Pixel_9_API_35") }
        let tabletLaunch = Task { try? await service.launch(avdName: "Tablet_API_35") }
        await commands.waitUntilBothLaunchesAwaitConfirmation()

        let requests = await launcher.requests
        #expect(Set(requests.map(\.consolePort)) == [5554, 5556])

        await commands.releaseConfirmations()
        await pixelLaunch.value
        await tabletLaunch.value
    }

    @Test func stopRejectsPhysicalDeviceSerialBeforeRunningADB() async {
        let commands = StubCommandRunner(results: [:])
        let service = AndroidEmulatorService(
            sdkLocator: StubSDKLocator(resolution: .available(Self.installation)),
            commands: commands,
            processLauncher: RecordingAndroidEmulatorLauncher()
        )

        await #expect(throws: AndroidEmulatorError.invalidEmulatorSerial("R58M123")) {
            try await service.stop(avdName: "Pixel_9_API_35", serial: "R58M123", transportID: "42")
        }
        #expect(await commands.invocations.isEmpty)
    }

    @Test func stopRejectsConsoleErrorReturnedWithZeroExitStatus() async {
        let installation = Self.installation
        let commands = StubCommandRunner(results: [
            StubCommand(
                executable: installation.adbURL!.path,
                arguments: ["devices", "-l"]
            ): .success("List of devices attached\nemulator-5554\tdevice transport_id:42\n"),
            StubCommand(
                executable: installation.adbURL!.path,
                arguments: ["-t", "42", "emu", "avd", "name"]
            ): .success("Pixel_9_API_35\nOK\n"),
            StubCommand(
                executable: installation.adbURL!.path,
                arguments: ["-t", "42", "emu", "kill"]
            ): .success("KO: emulator refused to stop\nOK\n"),
        ])
        let service = AndroidEmulatorService(
            sdkLocator: StubSDKLocator(resolution: .available(installation)),
            commands: commands,
            processLauncher: RecordingAndroidEmulatorLauncher()
        )

        await #expect(throws: AndroidEmulatorError.self) {
            try await service.stop(
                avdName: "Pixel_9_API_35",
                serial: "emulator-5554",
                transportID: "42"
            )
        }

        #expect(await commands.invocations.count == 3)
    }

    @Test func stopAcceptsTheOriginalTransportWhileADBReportsItOffline() async throws {
        let installation = Self.installation
        let disconnectFailure = CommandResult(
            stdout: nil,
            stderr: "error: device offline",
            exitStatus: 1,
            timedOut: false,
            executionError: nil
        )
        let commands = SequencedCommandRunner(results: [
            .success("List of devices attached\nemulator-5554\tdevice transport_id:42\n"),
            .success("Pixel_9_API_35\nOK\n"),
            .success("OK: killing emulator, bye bye\n"),
            disconnectFailure,
            .success("List of devices attached\nemulator-5554\toffline transport_id:42\n"),
        ])
        let service = AndroidEmulatorService(
            sdkLocator: StubSDKLocator(resolution: .available(installation)),
            commands: commands,
            processLauncher: RecordingAndroidEmulatorLauncher()
        )

        try await service.stop(
            avdName: "Pixel_9_API_35",
            serial: "emulator-5554",
            transportID: "42"
        )

        #expect(await commands.invocations.count == 5)
    }

    @Test func stopRejectsReusedSerialOwnedByDifferentAVD() async {
        let installation = Self.installation
        let commands = StubCommandRunner(results: [
            StubCommand(
                executable: installation.adbURL!.path,
                arguments: ["devices", "-l"]
            ): .success("List of devices attached\nemulator-5554\tdevice transport_id:77\n"),
            StubCommand(
                executable: installation.adbURL!.path,
                arguments: ["-t", "77", "emu", "avd", "name"]
            ): .success("Tablet_API_35\nOK\n"),
        ])
        let service = AndroidEmulatorService(
            sdkLocator: StubSDKLocator(resolution: .available(installation)),
            commands: commands,
            processLauncher: RecordingAndroidEmulatorLauncher()
        )

        await #expect(throws: AndroidEmulatorError.avdIdentityChanged(
            expected: "Pixel_9_API_35",
            actual: "Tablet_API_35"
        )) {
            try await service.stop(
                avdName: "Pixel_9_API_35",
                serial: "emulator-5554",
                transportID: "77"
            )
        }

        #expect(await commands.invocations.count == 2)
    }

    @Test func stopRejectsReplacementTransportEvenForSameAVDName() async {
        let installation = Self.installation
        let commands = StubCommandRunner(results: [
            StubCommand(
                executable: installation.adbURL!.path,
                arguments: ["devices", "-l"]
            ): .success("List of devices attached\nemulator-5554\tdevice transport_id:77\n"),
        ])
        let service = AndroidEmulatorService(
            sdkLocator: StubSDKLocator(resolution: .available(installation)),
            commands: commands,
            processLauncher: RecordingAndroidEmulatorLauncher()
        )

        await #expect(throws: AndroidEmulatorError.stopNotConfirmed(serial: "emulator-5554")) {
            try await service.stop(
                avdName: "Pixel_9_API_35",
                serial: "emulator-5554",
                transportID: "42"
            )
        }

        #expect(await commands.invocations.count == 1)
    }

    @Test func snapshotResolvesConnectedEmulatorNamesConcurrently() async throws {
        let commands = ConcurrentNameQueryCommandRunner(installation: Self.installation)
        let service = AndroidEmulatorService(
            sdkLocator: StubSDKLocator(resolution: .available(Self.installation)),
            commands: commands,
            processLauncher: RecordingAndroidEmulatorLauncher()
        )

        let queryCounts = await commands.nameQueryCountStream()
        let snapshotTask = Task { try await service.snapshot() }
        let reachedWorkerLimit = await Self.waitForQueryCount(4, in: queryCounts)
        await commands.releaseNameQueries()
        _ = try await snapshotTask.value

        #expect(reachedWorkerLimit)
        #expect(await commands.maximumConcurrentNameQueries == 4)
    }

    @Test func unresolvedConnectedEmulatorMarksStoppedAVDsUnavailable() async throws {
        let installation = Self.installation
        let commands = StubCommandRunner(results: [
            StubCommand(
                executable: installation.emulatorURL.path,
                arguments: ["-list-avds"]
            ): .success("Pixel_9_API_35\nTablet_API_35\n"),
            StubCommand(
                executable: installation.adbURL!.path,
                arguments: ["devices", "-l"]
            ): .success("List of devices attached\nemulator-5554\toffline transport_id:42\n"),
            StubCommand(
                executable: installation.adbURL!.path,
                arguments: ["-s", "emulator-5554", "emu", "avd", "name"]
            ): CommandResult(
                stdout: "",
                stderr: "offline",
                exitStatus: 1,
                timedOut: false,
                executionError: nil
            ),
        ])
        let service = AndroidEmulatorService(
            sdkLocator: StubSDKLocator(resolution: .available(installation)),
            commands: commands,
            processLauncher: RecordingAndroidEmulatorLauncher()
        )

        let snapshot = try await service.snapshot()

        #expect(snapshot.devices.map(\.state) == [.unavailable, .unavailable])
        #expect(snapshot.warning == .adbQueryFailed(detail: "offline"))
    }

    private static func waitForQueryCount(
        _ expectedCount: Int,
        in counts: AsyncStream<Int>
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await count in counts where count >= expectedCount {
                    return true
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    private static let installation = AndroidSDKInstallation(
        rootURL: URL(fileURLWithPath: "/sdk", isDirectory: true),
        emulatorURL: URL(fileURLWithPath: "/sdk/emulator/emulator"),
        adbURL: URL(fileURLWithPath: "/sdk/platform-tools/adb")
    )
}
