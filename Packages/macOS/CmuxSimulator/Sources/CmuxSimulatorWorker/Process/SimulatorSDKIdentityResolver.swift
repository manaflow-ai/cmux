import CmuxSimulator
import CryptoKit
import Foundation

struct SimulatorSDKIdentityResolver: Sendable {
    typealias Runner = @Sendable (SimulatorCommandDescriptor) async throws
        -> SimulatorSubprocessResult
    typealias Reader = @Sendable (URL) -> Data?

    private let runner: Runner
    private let reader: Reader

    init(
        runner: @escaping Runner,
        reader: @escaping Reader = readSimulatorSDKSettings
    ) {
        self.runner = runner
        self.reader = reader
    }

    func resolve() async throws -> SimulatorSDKIdentity {
        let path = try await value(for: pathCommand(), label: "path")
        async let version = value(for: versionCommand(), label: "version")
        async let buildVersion = value(for: buildVersionCommand(), label: "build version")
        async let compilerVersion = value(for: compilerVersionCommand(), label: "compiler version")
        let settingsDigest = try settingsDigest(sdkPath: path)
        return try await SimulatorSDKIdentity(
            path: path,
            version: version,
            buildVersion: buildVersion,
            compilerVersion: compilerVersion,
            settingsDigest: settingsDigest
        )
    }

    func pathCommand() -> SimulatorCommandDescriptor {
        simulatorXcrunCommand(["--sdk", "iphonesimulator", "--show-sdk-path"])
    }

    func versionCommand() -> SimulatorCommandDescriptor {
        simulatorXcrunCommand(["--sdk", "iphonesimulator", "--show-sdk-version"])
    }

    func buildVersionCommand() -> SimulatorCommandDescriptor {
        simulatorXcrunCommand(["--sdk", "iphonesimulator", "--show-sdk-build-version"])
    }

    func compilerVersionCommand() -> SimulatorCommandDescriptor {
        simulatorXcrunCommand(["--sdk", "iphonesimulator", "clang", "--version"])
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

    private func settingsDigest(sdkPath: String) throws -> String {
        let root = URL(fileURLWithPath: sdkPath, isDirectory: true)
        let names = ["SDKSettings.plist", "SDKSettings.json"]
        var content = Data()
        var found = false
        for name in names {
            let url = root.appendingPathComponent(name)
            guard let data = reader(url) else { continue }
            found = true
            appendSDKSettingsField(name, to: &content)
            appendSDKSettingsField(data, to: &content)
        }
        guard found else {
            throw SimulatorWorkerFailure.frameworkUnavailable(
                "The active iPhone Simulator SDK has no readable settings identity."
            )
        }
        return SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
    }
}

private func readSimulatorSDKSettings(_ url: URL) -> Data? {
    try? Data(contentsOf: url)
}

private func simulatorXcrunCommand(_ arguments: [String]) -> SimulatorCommandDescriptor {
    SimulatorCommandDescriptor(executable: "/usr/bin/xcrun", arguments: arguments)
}

private func appendSDKSettingsField(_ value: String, to data: inout Data) {
    appendSDKSettingsField(Data(value.utf8), to: &data)
}

private func appendSDKSettingsField(_ value: Data, to data: inout Data) {
    var count = UInt64(value.count).bigEndian
    withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
    data.append(value)
}
