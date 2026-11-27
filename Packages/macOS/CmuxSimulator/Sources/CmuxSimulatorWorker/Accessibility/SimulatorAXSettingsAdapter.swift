import CmuxSimulator
import Foundation

/// Compiles and drives serve-sim's in-Simulator accessibility settings helper.
///
/// The helper owns every private symbol lookup. This macOS worker only invokes
/// `xcrun`, `clang`, and `simctl` with explicit argument vectors, so compiler or
/// runtime failures remain recoverable worker errors.
@MainActor
final class SimulatorAXSettingsAdapter {
    typealias Runner = @Sendable (SimulatorCommandDescriptor) async throws -> SimulatorSubprocessResult

    private let sourceURL: URL?
    private let cacheDirectoryURL: URL
    private let fileManager: FileManager
    private let temporaryName: @Sendable () -> String
    private let runner: Runner
    private var cachedExecutableURL: URL?
    private var cachedExecutableKey: String?

    var isAvailable: Bool {
        resolvedSourceURL.map { fileManager.isReadableFile(atPath: $0.path) } ?? false
    }

    init(
        sourceURL: URL? = nil,
        cacheDirectoryURL: URL? = nil,
        fileManager: FileManager = .default,
        temporaryName: @escaping @Sendable () -> String = { UUID().uuidString },
        subprocessRunner: SimulatorSubprocessRunner = SimulatorSubprocessRunner(),
        runner: Runner? = nil
    ) {
        self.sourceURL = sourceURL
        self.cacheDirectoryURL = cacheDirectoryURL
            ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first?
                .appendingPathComponent("com.cmuxterm.simulator-tools", isDirectory: true)
            ?? fileManager.temporaryDirectory
                .appendingPathComponent("com.cmuxterm.simulator-tools", isDirectory: true)
        self.fileManager = fileManager
        self.temporaryName = temporaryName
        self.runner = runner ?? { descriptor in
            try await subprocessRunner.run(
                executableURL: URL(fileURLWithPath: descriptor.executable),
                arguments: descriptor.arguments
            )
        }
    }

    func set(
        deviceIdentifier: String,
        setting: SimulatorInterfaceSetting
    ) async throws {
        guard let projection = simulatorAXProjection(for: setting) else {
            throw SimulatorWorkerFailure.privateAPIUnavailable(
                "The requested interface setting does not use the accessibility helper."
            )
        }
        _ = try await runTool(
            deviceIdentifier: deviceIdentifier,
            arguments: ["set", projection.key.rawValue, projection.value]
        )
    }

    func status(deviceIdentifier: String) async throws -> SimulatorInterfaceStatus {
        async let appearance = publicInterfaceValue(
            deviceIdentifier: deviceIdentifier,
            option: "appearance"
        )
        async let contentSize = publicInterfaceValue(
            deviceIdentifier: deviceIdentifier,
            option: "content_size"
        )
        async let increaseContrast = publicInterfaceValue(
            deviceIdentifier: deviceIdentifier,
            option: "increase_contrast"
        )
        let output = try await runTool(
            deviceIdentifier: deviceIdentifier,
            arguments: ["status"]
        )
        let privateStatus = try parseSimulatorAXStatus(output)
        return await SimulatorInterfaceStatus(
            appearance: simulatorAppearance(from: appearance),
            contentSize: simulatorContentSize(from: contentSize),
            increaseContrast: simulatorIncreaseContrast(from: increaseContrast),
            liquidGlass: privateStatus.liquidGlass,
            colorFilter: privateStatus.colorFilter,
            reduceMotion: privateStatus.reduceMotion,
            buttonShapes: privateStatus.buttonShapes,
            reduceTransparency: privateStatus.reduceTransparency,
            voiceOver: privateStatus.voiceOver
        )
    }

    func value(
        deviceIdentifier: String,
        key: SimulatorAXSettingsKey
    ) async throws -> String {
        try await runTool(
            deviceIdentifier: deviceIdentifier,
            arguments: ["get", key.rawValue]
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var resolvedSourceURL: URL? {
        sourceURL ?? Bundle.module.resourceURL?
            .appendingPathComponent("SimulatorAXSettings/sim-ax-settings.m.txt")
    }

    private func publicInterfaceValue(
        deviceIdentifier: String,
        option: String
    ) async -> String? {
        do {
            let result = try await runner(simulatorPublicInterfaceCommand(
                deviceIdentifier: deviceIdentifier,
                option: option
            ))
            guard result.status == 0 else { return nil }
            let value = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value.lowercased()
        } catch {
            return nil
        }
    }

    private func runTool(
        deviceIdentifier: String,
        arguments: [String]
    ) async throws -> String {
        let executableURL = try await compiledExecutable()
        let descriptor = simulatorAXSpawnCommand(
            deviceIdentifier: deviceIdentifier,
            executableURL: executableURL,
            arguments: arguments
        )
        let result = try await runner(descriptor)
        guard result.status == 0 else {
            throw simulatorAXFailure(
                result,
                fallback: "The in-Simulator accessibility helper failed."
            )
        }
        return result.standardOutput
    }

    private func compiledExecutable() async throws -> URL {
        guard let sourceURL = resolvedSourceURL,
              let sourceData = try? Data(contentsOf: sourceURL) else {
            throw SimulatorWorkerFailure.frameworkUnavailable(
                "The bundled accessibility helper source is unavailable."
            )
        }

        let sdk = try await SimulatorSDKIdentityResolver(runner: runner).resolve()
        let cacheKey = SimulatorBuildInputs(
            sources: [SimulatorBuildSource(name: sourceURL.lastPathComponent, data: sourceData)],
            compileArguments: simulatorAXCompileCommand(
                sourceURL: URL(fileURLWithPath: "<SOURCE>"),
                sdkPath: "<SDKROOT>",
                outputURL: URL(fileURLWithPath: "<OUTPUT>")
            ).arguments,
            sdk: sdk
        ).cacheKey
        if cachedExecutableKey == cacheKey,
           let cachedExecutableURL,
           fileManager.isExecutableFile(atPath: cachedExecutableURL.path) {
            return cachedExecutableURL
        }
        let directory = cacheDirectoryURL
            .appendingPathComponent("sim-ax-settings-\(cacheKey)", isDirectory: true)
        let destination = directory.appendingPathComponent("sim-ax-settings")
        if fileManager.isExecutableFile(atPath: destination.path) {
            cachedExecutableURL = destination
            cachedExecutableKey = cacheKey
            return destination
        }

        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw SimulatorWorkerFailure.frameworkUnavailable(
                "The accessibility helper cache directory could not be created: \(error)"
            )
        }
        let temporary = directory.appendingPathComponent("sim-ax-settings-\(temporaryName())")
        defer { try? fileManager.removeItem(at: temporary) }
        let compileResult = try await runner(simulatorAXCompileCommand(
            sourceURL: sourceURL,
            sdkPath: sdk.path,
            outputURL: temporary
        ))
        guard compileResult.status == 0 else {
            throw simulatorAXFailure(
                compileResult,
                fallback: "The active Xcode could not compile the accessibility helper."
            )
        }
        do {
            try fileManager.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: temporary.path
            )
            if fileManager.fileExists(atPath: destination.path) {
                guard fileManager.isExecutableFile(atPath: destination.path) else {
                    try fileManager.removeItem(at: destination)
                    try fileManager.moveItem(at: temporary, to: destination)
                    cachedExecutableURL = destination
                    cachedExecutableKey = cacheKey
                    return destination
                }
            } else {
                try fileManager.moveItem(at: temporary, to: destination)
            }
        } catch {
            throw SimulatorWorkerFailure.frameworkUnavailable(
                "The compiled accessibility helper could not enter the cache: \(error)"
            )
        }
        guard fileManager.isExecutableFile(atPath: destination.path) else {
            throw SimulatorWorkerFailure.frameworkUnavailable(
                "The compiled accessibility helper is not executable."
            )
        }
        cachedExecutableURL = destination
        cachedExecutableKey = cacheKey
        return destination
    }

}

func simulatorAXCompileCommand(
    sourceURL: URL,
    sdkPath: String,
    outputURL: URL
) -> SimulatorCommandDescriptor {
    SimulatorCommandDescriptor(
        executable: "/usr/bin/xcrun",
        arguments: [
            "--sdk", "iphonesimulator", "clang",
            "-x", "objective-c",
            "-arch", "arm64",
            "-arch", "x86_64",
            "-mios-simulator-version-min=15.0",
            "-isysroot", sdkPath,
            "-framework", "CoreFoundation",
            "-o", outputURL.path,
            sourceURL.path,
        ]
    )
}

func simulatorAXSpawnCommand(
    deviceIdentifier: String,
    executableURL: URL,
    arguments: [String]
) -> SimulatorCommandDescriptor {
    SimulatorCommandDescriptor(
        executable: "/usr/bin/xcrun",
        arguments: [
            "simctl", "spawn", deviceIdentifier, executableURL.path,
        ] + arguments
    )
}

func simulatorPublicInterfaceCommand(
    deviceIdentifier: String,
    option: String
) -> SimulatorCommandDescriptor {
    SimulatorCommandDescriptor(
        executable: "/usr/bin/xcrun",
        arguments: ["simctl", "ui", deviceIdentifier, option]
    )
}

func parseSimulatorAXStatus(_ output: String) throws -> SimulatorInterfaceStatus {
    do {
        let wire = try JSONDecoder().decode(SimulatorAXWireStatus.self, from: Data(output.utf8))
        guard let liquidGlass = SimulatorInterfaceSetting.LiquidGlass(rawValue: wire.liquidGlass),
              let colorFilter = SimulatorInterfaceSetting.ColorFilter(rawValue: wire.colorFilter),
              let reduceMotion = simulatorAXToggle(wire.reduceMotion),
              let buttonShapes = simulatorAXToggle(wire.showBorders),
              let reduceTransparency = simulatorAXToggle(wire.reduceTransparency),
              let voiceOver = simulatorAXToggle(wire.voiceOver)
        else {
            throw SimulatorWorkerFailure.privateAPIUnavailable(
                "The accessibility helper returned an unsupported setting value."
            )
        }
        return SimulatorInterfaceStatus(
            liquidGlass: liquidGlass,
            colorFilter: colorFilter,
            reduceMotion: reduceMotion,
            buttonShapes: buttonShapes,
            reduceTransparency: reduceTransparency,
            voiceOver: voiceOver
        )
    } catch let error as SimulatorWorkerFailure {
        throw error
    } catch {
        throw SimulatorWorkerFailure.privateAPIUnavailable(
            "The accessibility helper returned unreadable status JSON: \(error)"
        )
    }
}

private func simulatorAXProjection(
    for setting: SimulatorInterfaceSetting
) -> (key: SimulatorAXSettingsKey, value: String)? {
    switch setting {
    case let .liquidGlass(value):
        (.liquidGlass, value.rawValue)
    case let .colorFilter(value):
        (.colorFilter, value.rawValue)
    case let .reduceMotion(enabled):
        (.reduceMotion, enabled ? "on" : "off")
    case let .buttonShapes(enabled):
        (.showBorders, enabled ? "on" : "off")
    case let .reduceTransparency(enabled):
        (.reduceTransparency, enabled ? "on" : "off")
    case let .voiceOver(enabled):
        (.voiceOver, enabled ? "on" : "off")
    default:
        nil
    }
}

private func simulatorAXToggle(_ value: String) -> Bool? {
    switch value {
    case "on": true
    case "off": false
    default: nil
    }
}

private func simulatorAppearance(
    from value: String?
) -> SimulatorInterfaceSetting.Appearance? {
    value.flatMap(SimulatorInterfaceSetting.Appearance.init(rawValue:))
}

private func simulatorContentSize(
    from value: String?
) -> SimulatorInterfaceSetting.ContentSize? {
    value.flatMap(SimulatorInterfaceSetting.ContentSize.init(rawValue:))
}

private func simulatorIncreaseContrast(from value: String?) -> Bool? {
    switch value {
    case "enabled": true
    case "disabled": false
    default: nil
    }
}

private func simulatorAXFailure(
    _ result: SimulatorSubprocessResult,
    fallback: String
) -> SimulatorWorkerFailure {
    let detail = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
    return .frameworkUnavailable(detail.isEmpty ? fallback : detail)
}
