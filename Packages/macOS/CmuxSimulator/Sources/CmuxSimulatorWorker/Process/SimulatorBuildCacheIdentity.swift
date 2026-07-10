import CmuxSimulator
import CryptoKit
import Foundation

struct SimulatorSDKIdentity: Equatable, Sendable {
    let path: String
    let version: String
    let buildVersion: String
    let compilerVersion: String
    let settingsDigest: String
}

struct SimulatorBuildSource: Equatable, Sendable {
    let name: String
    let data: Data
}

struct SimulatorBuildInputs: Equatable, Sendable {
    let sources: [SimulatorBuildSource]
    let compileArguments: [String]
    let sdk: SimulatorSDKIdentity

    var cacheKey: String {
        var data = Data()
        appendCacheField("cmux-simulator-build-cache-v1", to: &data)
        appendCacheField(sdk.path, to: &data)
        appendCacheField(sdk.version, to: &data)
        appendCacheField(sdk.buildVersion, to: &data)
        appendCacheField(sdk.compilerVersion, to: &data)
        appendCacheField(sdk.settingsDigest, to: &data)
        for argument in compileArguments {
            appendCacheField(argument, to: &data)
        }
        for source in sources {
            appendCacheField(source.name, to: &data)
            appendCacheField(source.data, to: &data)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct SimulatorSDKIdentityResolver: Sendable {
    typealias Runner = @Sendable (SimulatorCommandDescriptor) async throws
        -> SimulatorSubprocessResult

    private let runner: Runner

    init(runner: @escaping Runner) {
        self.runner = runner
    }

    func resolve() async throws -> SimulatorSDKIdentity {
        let path = try await value(for: Self.pathCommand(), label: "path")
        async let version = value(for: Self.versionCommand(), label: "version")
        async let buildVersion = value(for: Self.buildVersionCommand(), label: "build version")
        async let compilerVersion = value(for: Self.compilerVersionCommand(), label: "compiler version")
        let settingsDigest = try Self.settingsDigest(sdkPath: path)
        return try await SimulatorSDKIdentity(
            path: path,
            version: version,
            buildVersion: buildVersion,
            compilerVersion: compilerVersion,
            settingsDigest: settingsDigest
        )
    }

    nonisolated static func pathCommand() -> SimulatorCommandDescriptor {
        xcrunCommand(["--sdk", "iphonesimulator", "--show-sdk-path"])
    }

    nonisolated static func versionCommand() -> SimulatorCommandDescriptor {
        xcrunCommand(["--sdk", "iphonesimulator", "--show-sdk-version"])
    }

    nonisolated static func buildVersionCommand() -> SimulatorCommandDescriptor {
        xcrunCommand(["--sdk", "iphonesimulator", "--show-sdk-build-version"])
    }

    nonisolated static func compilerVersionCommand() -> SimulatorCommandDescriptor {
        xcrunCommand(["--sdk", "iphonesimulator", "clang", "--version"])
    }

    private func value(
        for command: SimulatorCommandDescriptor,
        label: String
    ) async throws -> String {
        let result = try await runner(command)
        let output = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.status == 0, !output.isEmpty else {
            let detail = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SimulatorWorkerFailure.frameworkUnavailable(
                detail.isEmpty
                    ? "The active iPhone Simulator SDK has no \(label) identity."
                    : detail
            )
        }
        return output
    }

    private nonisolated static func settingsDigest(sdkPath: String) throws -> String {
        let root = URL(fileURLWithPath: sdkPath, isDirectory: true)
        let names = ["SDKSettings.plist", "SDKSettings.json"]
        var content = Data()
        var found = false
        for name in names {
            let url = root.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url) else { continue }
            found = true
            appendCacheField(name, to: &content)
            appendCacheField(data, to: &content)
        }
        guard found else {
            throw SimulatorWorkerFailure.frameworkUnavailable(
                "The active iPhone Simulator SDK has no readable settings identity."
            )
        }
        return SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func xcrunCommand(
        _ arguments: [String]
    ) -> SimulatorCommandDescriptor {
        SimulatorCommandDescriptor(executable: "/usr/bin/xcrun", arguments: arguments)
    }
}

private func appendCacheField(_ value: String, to data: inout Data) {
    appendCacheField(Data(value.utf8), to: &data)
}

private func appendCacheField(_ value: Data, to data: inout Data) {
    var count = UInt64(value.count).bigEndian
    withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
    data.append(value)
}
