import CmuxNextRemote
import CryptoKit
import Foundation

/// Install Browser on Machine, upload from this Mac (cx-2cob slice 2; the
/// chief's decision until a public host bundle exists): the app's own host
/// app (`Contents/Helpers/cmux-remote-browser-host.app`, DEV builds) is sent
/// over the machine's SSH link with its CEF framework (`tar -h` follows the
/// framework symlink) and installed by `RemoteBrowserHostInstall`. macOS
/// arm64 machines only (the Linux host is slice 4).
@MainActor
struct MachineBrowserInstall {
    let services: AppServices

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static var helper: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/cmux-remote-browser-host.app")
    }

    /// Installs this build's browser on `machine`; returns the version.
    func install(machine: String) async throws -> String {
        guard let session = services.machines.sshSession(machine) else { throw Failure(description: "\(machine) is not an SSH machine") }
        guard let client = services.remoteLocalhost.loopbackClient(machine: machine) else { throw Failure(description: "\(machine) is not connected") }
        let status = try await client.browserRuntimeStatus()
        guard status.platform == "macos-aarch64" else {
            throw Failure(description: "the browser runs on macOS arm64 machines; \(machine) is \(status.platform)")
        }
        let helper = Self.helper
        let binary = helper.appendingPathComponent("Contents/MacOS/cmux-remote-browser-host")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { throw Failure(description: "this build has no browser host") }
        let version = try await Self.sha256(binary)
        guard let plan = RemoteBrowserHostInstall(version: version) else { throw Failure(description: "bad host digest") }
        if status.installed == version { return version }
        let bundle = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-browser-host-\(UUID().uuidString).tgz")
        defer { try? FileManager.default.removeItem(at: bundle) }
        let environment = await SSHService.environment()
        let packed = try await SSHProcessRunner.run(
            ["/usr/bin/tar", "-czhf", bundle.path, "-C", helper.deletingLastPathComponent().path, helper.lastPathComponent],
            environment: environment, deadline: .seconds(10 * 60), label: "pack the browser host")
        guard packed.status == 0 else { throw Failure(description: packed.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let result = try await plan.run(on: session.host, bundle: bundle, environment: environment)
        guard result.status == 0 else { throw Failure(description: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
        services.machineBrowserHosts.refresh(machine)
        return version
    }

    private nonisolated static func sha256(_ file: URL) async throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
