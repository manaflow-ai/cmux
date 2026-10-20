import CmuxSimulator
import Foundation
import Testing
@testable import CmuxSimulatorWorker

@Suite("Simulator accessibility settings helper")
struct SimulatorAXSettingsAdapterTests {
    @Test("Compiler and spawn commands keep every value in argv")
    func commandDescriptorsAreArgvBased() {
        let compile = simulatorAXCompileCommand(
            sourceURL: URL(fileURLWithPath: "/source/helper.m.txt"),
            sdkPath: "/Xcode/Simulator.sdk",
            outputURL: URL(fileURLWithPath: "/cache/helper")
        )
        #expect(compile.executable == "/usr/bin/xcrun")
        #expect(compile.arguments == [
            "--sdk", "iphonesimulator", "clang", "-x", "objective-c",
            "-arch", "arm64", "-arch", "x86_64",
            "-mios-simulator-version-min=15.0",
            "-isysroot", "/Xcode/Simulator.sdk",
            "-framework", "CoreFoundation", "-o", "/cache/helper",
            "/source/helper.m.txt",
        ])

        let spawn = simulatorAXSpawnCommand(
            deviceIdentifier: "DEVICE",
            executableURL: URL(fileURLWithPath: "/cache/helper"),
            arguments: ["set", "show-borders", "on"]
        )
        #expect(spawn.executable == "/usr/bin/xcrun")
        #expect(spawn.arguments == [
            "simctl", "spawn", "DEVICE", "/cache/helper", "set", "show-borders", "on",
        ])

        #expect(simulatorPublicInterfaceCommand(
            deviceIdentifier: "DEVICE",
            option: "content_size"
        ).arguments == ["simctl", "ui", "DEVICE", "content_size"])
    }

    @Test("Status JSON maps every serve-sim setting")
    func parsesStatus() throws {
        let status = try parseSimulatorAXStatus(#"{"reduce-motion":"on","show-borders":"off","reduce-transparency":"on","voiceover":"off","color-filter":"green-red","liquid-glass":"tinted"}"#)

        #expect(status == SimulatorInterfaceStatus(
            liquidGlass: .tinted,
            colorFilter: .greenRed,
            reduceMotion: true,
            buttonShapes: false,
            reduceTransparency: true,
            voiceOver: false
        ))
    }

    @Test("Status merges public values and recompiles after an in-place SDK change")
    @MainActor
    func compilesOnce() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-sim-ax-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("helper.m.txt")
        #expect(FileManager.default.createFile(atPath: source.path, contents: Data("source".utf8)))
        let sdk = root.appendingPathComponent("iPhoneSimulator.sdk", isDirectory: true)
        try FileManager.default.createDirectory(at: sdk, withIntermediateDirectories: true)
        let settings = sdk.appendingPathComponent("SDKSettings.plist")
        try Data("sdk-settings-one".utf8).write(to: settings)
        let fake = AXSettingsRunnerFake(sdkPath: sdk.path)
        let adapter = SimulatorAXSettingsAdapter(
            sourceURL: source,
            cacheDirectoryURL: root.appendingPathComponent("cache"),
            runner: { descriptor in try await fake.run(descriptor) }
        )

        let first = try await adapter.status(deviceIdentifier: "DEVICE")
        try await adapter.set(deviceIdentifier: "DEVICE", setting: .buttonShapes(true))
        let value = try await adapter.value(deviceIdentifier: "DEVICE", key: .reduceMotion)
        try Data("sdk-settings-two".utf8).write(to: settings)
        let second = try await adapter.status(deviceIdentifier: "DEVICE")

        #expect(first == second)
        #expect(first.appearance == .dark)
        #expect(first.contentSize == .accessibilityLarge)
        #expect(first.increaseContrast == true)
        #expect(value == "on")
        let commands = await fake.commands
        #expect(commands.filter { $0.arguments.contains("-o") }.count == 2)
        #expect(commands.contains { $0.arguments.suffix(3) == ["set", "show-borders", "on"] })
        #expect(commands.contains { $0.arguments.suffix(2) == ["get", "reduce-motion"] })
        #expect(commands.filter { $0.arguments.last == "status" }.count == 2)
        #expect(commands.filter { $0.arguments.suffix(4) == ["simctl", "ui", "DEVICE", "appearance"] }.count == 2)
    }
}
