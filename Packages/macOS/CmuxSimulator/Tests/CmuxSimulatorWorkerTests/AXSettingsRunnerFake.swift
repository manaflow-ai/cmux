import CmuxSimulator
import Foundation
import Testing
@testable import CmuxSimulatorWorker

actor AXSettingsRunnerFake {
    private let sdkPath: String
    private(set) var commands: [SimulatorCommandDescriptor] = []

    init(sdkPath: String) {
        self.sdkPath = sdkPath
    }

    func run(_ command: SimulatorCommandDescriptor) throws -> SimulatorSubprocessResult {
        commands.append(command)
        if command.arguments == ["--sdk", "iphonesimulator", "--show-sdk-path"] {
            return SimulatorSubprocessResult(
                status: 0,
                standardOutput: "\(sdkPath)\n",
                standardError: ""
            )
        }
        if command.arguments == ["--sdk", "iphonesimulator", "--show-sdk-version"] {
            return SimulatorSubprocessResult(status: 0, standardOutput: "26.0\n", standardError: "")
        }
        if command.arguments == ["--sdk", "iphonesimulator", "--show-sdk-build-version"] {
            return SimulatorSubprocessResult(status: 0, standardOutput: "23A1\n", standardError: "")
        }
        if command.arguments == ["--sdk", "iphonesimulator", "clang", "--version"] {
            return SimulatorSubprocessResult(
                status: 0,
                standardOutput: "Apple clang version test\n",
                standardError: ""
            )
        }
        if command.arguments.contains("-o") {
            let outputIndex = try #require(command.arguments.firstIndex(of: "-o"))
            let output = command.arguments[outputIndex + 1]
            #expect(FileManager.default.createFile(atPath: output, contents: Data([0xcf, 0xfa])))
            return SimulatorSubprocessResult(status: 0, standardOutput: "", standardError: "")
        }
        if command.arguments.suffix(4) == ["simctl", "ui", "DEVICE", "appearance"] {
            return SimulatorSubprocessResult(status: 0, standardOutput: "Dark\n", standardError: "")
        }
        if command.arguments.suffix(4) == ["simctl", "ui", "DEVICE", "content_size"] {
            return SimulatorSubprocessResult(
                status: 0,
                standardOutput: "Accessibility-Large\n",
                standardError: ""
            )
        }
        if command.arguments.suffix(4) == ["simctl", "ui", "DEVICE", "increase_contrast"] {
            return SimulatorSubprocessResult(status: 0, standardOutput: "enabled\n", standardError: "")
        }
        if command.arguments.last == "status" {
            return SimulatorSubprocessResult(
                status: 0,
                standardOutput: #"{"reduce-motion":"on","show-borders":"off","reduce-transparency":"on","voiceover":"off","color-filter":"grayscale","liquid-glass":"clear"}"#,
                standardError: ""
            )
        }
        if command.arguments.suffix(2) == ["get", "reduce-motion"] {
            return SimulatorSubprocessResult(status: 0, standardOutput: "on\n", standardError: "")
        }
        return SimulatorSubprocessResult(status: 0, standardOutput: "", standardError: "")
    }
}
