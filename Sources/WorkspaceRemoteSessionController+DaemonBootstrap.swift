import Foundation
import SwiftUI
import AppKit
import Bonsplit
import CMUXAgentLaunch
import CmuxSocketControl
import Combine
import CryptoKit
import Darwin
import Network
import CoreText


// MARK: - Remote daemon bootstrap and binary provisioning
extension WorkspaceRemoteSessionController {
    private static let remotePlatformProbeHomeMarker = "__CMUX_REMOTE_HOME__="
    private static let remotePlatformProbeOSMarker = "__CMUX_REMOTE_OS__="
    private static let remotePlatformProbeArchMarker = "__CMUX_REMOTE_ARCH__="
    private static let remotePlatformProbeExistsMarker = "__CMUX_REMOTE_EXISTS__="
    var requiredDaemonCapabilities: [String] {
        WorkspaceRemoteDaemonRPCClient.requiredCapabilities(for: configuration)
    }

    var bakedDaemonPreflightRequiredCapabilities: [String] {
        requiredDaemonCapabilities.filter {
            $0 != WorkspaceRemoteDaemonRPCClient.requiredPTYSessionCapability &&
                $0 != WorkspaceRemoteDaemonRPCClient.requiredPTYSessionTokenCapability &&
                $0 != WorkspaceRemoteDaemonRPCClient.requiredPTYWriteNotificationCapability
        }
    }

    static func missingRequiredCapabilities(_ required: [String], in capabilities: [String]) -> [String] {
        WorkspaceRemoteDaemonRPCClient.missingRequiredCapabilities(required, in: capabilities)
    }

    static func userFacingRemoteDaemonBootstrapErrorMessage(_ error: Error) -> String {
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = message.lowercased()
        if lowered.contains("missing required capability") ||
            lowered.contains(WorkspaceRemoteDaemonRPCClient.requiredPTYSessionCapability) ||
            lowered.contains(WorkspaceRemoteDaemonRPCClient.requiredPTYSessionTokenCapability) ||
            lowered.contains(WorkspaceRemoteDaemonRPCClient.requiredPTYWriteNotificationCapability) {
            return remoteDaemonMissingRequiredCapabilitiesMessage([
                WorkspaceRemoteDaemonRPCClient.requiredPTYSessionCapability,
            ])
        }
        return message.isEmpty ? "remote daemon bootstrap failed" : message
    }

    func bootstrapDaemonLocked(requiredCapabilities: [String]) throws -> DaemonHello {
        debugLog("remote.bootstrap.begin \(debugConfigSummary())")
        let version = Self.remoteDaemonVersion()
        let bootstrapState = try probeRemoteBootstrapStateLocked(version: version)
        let platform = bootstrapState.platform
        let remoteLocation = try Self.remoteDaemonInstallLocation(
            version: version,
            goOS: platform.goOS,
            goArch: platform.goArch,
            homeDirectory: bootstrapState.homeDirectory
        )
        let remotePath = remoteLocation.absolutePath
        let explicitOverrideBinary = Self.explicitRemoteDaemonBinaryURL()
        let forceExplicitOverrideInstall = explicitOverrideBinary != nil
        debugLog(
            "remote.bootstrap.platform os=\(platform.goOS) arch=\(platform.goArch) " +
            "version=\(version) remotePath=\(remotePath) relativePath=\(remoteLocation.relativePath) " +
            "allowLocalBuildFallback=\(Self.allowLocalDaemonBuildFallback() ? 1 : 0) " +
            "explicitOverride=\(forceExplicitOverrideInstall ? 1 : 0)"
        )

        let hadExistingBinary = bootstrapState.binaryExists
        debugLog("remote.bootstrap.binaryExists remotePath=\(remotePath) exists=\(hadExistingBinary ? 1 : 0)")
        if forceExplicitOverrideInstall || !hadExistingBinary {
            let localBinary = try buildLocalDaemonBinary(goOS: platform.goOS, goArch: platform.goArch, version: version)
            try uploadRemoteDaemonBinaryLocked(localBinary: localBinary, location: remoteLocation)
        }

        var hello: DaemonHello
        do {
            hello = try helloRemoteDaemonLocked(remotePath: remotePath)
        } catch {
            guard hadExistingBinary else {
                throw error
            }
            debugLog(
                "remote.bootstrap.helloRetry remotePath=\(remotePath) " +
                "detail=\(error.localizedDescription)"
            )
            let localBinary = try buildLocalDaemonBinary(goOS: platform.goOS, goArch: platform.goArch, version: version)
            try uploadRemoteDaemonBinaryLocked(localBinary: localBinary, location: remoteLocation)
            hello = try helloRemoteDaemonLocked(remotePath: remotePath)
        }
        let missingCapabilities = Self.missingRequiredCapabilities(requiredCapabilities, in: hello.capabilities)
        if hadExistingBinary, !missingCapabilities.isEmpty {
            debugLog(
                "remote.bootstrap.capabilityMissing remotePath=\(remotePath) " +
                "missing=\(missingCapabilities.joined(separator: ",")) capabilities=\(hello.capabilities.joined(separator: ","))"
            )
            let localBinary = try buildLocalDaemonBinary(goOS: platform.goOS, goArch: platform.goArch, version: version)
            try uploadRemoteDaemonBinaryLocked(localBinary: localBinary, location: remoteLocation)
            hello = try helloRemoteDaemonLocked(remotePath: remotePath)
        }

        debugLog(
            "remote.bootstrap.ready name=\(hello.name) version=\(hello.version) " +
            "capabilities=\(hello.capabilities.joined(separator: ",")) remotePath=\(hello.remotePath)"
        )
        if let connectionAttemptStartedAt {
            debugLog(
                "remote.timing.bootstrap.ready elapsedMs=\(Int(Date().timeIntervalSince(connectionAttemptStartedAt) * 1000)) " +
                "\(debugConfigSummary())"
            )
        }
        return hello
    }

    private func probeRemoteBootstrapStateLocked(version: String) throws -> RemoteBootstrapState {
        let script = """
        cmux_uname_os="$(uname -s)"
        cmux_uname_arch="$(uname -m)"
        printf '%s%s\\n' '\(Self.remotePlatformProbeHomeMarker)' "$HOME"
        printf '%s%s\\n' '\(Self.remotePlatformProbeOSMarker)' "$cmux_uname_os"
        printf '%s%s\\n' '\(Self.remotePlatformProbeArchMarker)' "$cmux_uname_arch"
        case "$(printf '%s' "$cmux_uname_os" | tr '[:upper:]' '[:lower:]')" in
          linux|darwin|freebsd) cmux_go_os="$(printf '%s' "$cmux_uname_os" | tr '[:upper:]' '[:lower:]')" ;;
          *) exit 70 ;;
        esac
        case "$(printf '%s' "$cmux_uname_arch" | tr '[:upper:]' '[:lower:]')" in
          x86_64|amd64) cmux_go_arch=amd64 ;;
          aarch64|arm64) cmux_go_arch=arm64 ;;
          armv7l) cmux_go_arch=arm ;;
          *) exit 71 ;;
        esac
        cmux_remote_path="$HOME/.cmux/bin/cmuxd-remote/\(version)/${cmux_go_os}-${cmux_go_arch}/cmuxd-remote"
        if [ -x "$cmux_remote_path" ]; then
          printf '%syes\\n' '\(Self.remotePlatformProbeExistsMarker)'
        else
          printf '%sno\\n' '\(Self.remotePlatformProbeExistsMarker)'
        fi
        """
        let command = "sh -c \(Self.shellSingleQuoted(script))"
        let result = try sshExec(arguments: sshCommonArguments(batchMode: true) + [configuration.destination, command], timeout: 20)

        let lines = result.stdout
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let unameOS = lines.first { $0.hasPrefix(Self.remotePlatformProbeOSMarker) }
            .map { String($0.dropFirst(Self.remotePlatformProbeOSMarker.count)) }
        let unameArch = lines.first { $0.hasPrefix(Self.remotePlatformProbeArchMarker) }
            .map { String($0.dropFirst(Self.remotePlatformProbeArchMarker.count)) }
        let homeDirectory = lines.first { $0.hasPrefix(Self.remotePlatformProbeHomeMarker) }
            .map { String($0.dropFirst(Self.remotePlatformProbeHomeMarker.count)) }
        guard let unameOS, let unameArch, let homeDirectory else {
            let detail = Self.bestErrorLine(stderr: result.stderr, stdout: result.stdout) ?? "ssh exited \(result.status)"
            throw NSError(domain: "cmux.remote.daemon", code: 11, userInfo: [
                NSLocalizedDescriptionKey: "failed to query remote platform: \(detail)",
            ])
        }

        guard let goOS = Self.mapUnameOS(unameOS),
              let goArch = Self.mapUnameArch(unameArch) else {
            throw NSError(domain: "cmux.remote.daemon", code: 12, userInfo: [
                NSLocalizedDescriptionKey: "unsupported remote platform \(unameOS)/\(unameArch)",
            ])
        }

        let binaryExists = lines.first { $0.hasPrefix(Self.remotePlatformProbeExistsMarker) }
            .map { String($0.dropFirst(Self.remotePlatformProbeExistsMarker.count)) == "yes" }
        if result.status != 0, binaryExists == nil {
            let detail = Self.bestErrorLine(stderr: result.stderr, stdout: result.stdout) ?? "ssh exited \(result.status)"
            throw NSError(domain: "cmux.remote.daemon", code: 13, userInfo: [
                NSLocalizedDescriptionKey: "failed to query remote daemon state: \(detail)",
            ])
        }

        return RemoteBootstrapState(
            platform: RemotePlatform(goOS: goOS, goArch: goArch),
            homeDirectory: homeDirectory,
            binaryExists: binaryExists ?? false
        )
    }

    static let remoteDaemonManifestInfoKey = "CMUXRemoteDaemonManifestJSON"

    static func remoteDaemonManifest(from infoDictionary: [String: Any]?) -> WorkspaceRemoteDaemonManifest? {
        guard let rawManifest = infoDictionary?[remoteDaemonManifestInfoKey] as? String else { return nil }
        let trimmed = rawManifest.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let data = trimmed.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(WorkspaceRemoteDaemonManifest.self, from: data)
    }

    private static func remoteDaemonManifest() -> WorkspaceRemoteDaemonManifest? {
        remoteDaemonManifest(from: Bundle.main.infoDictionary)
    }

    private static func remoteDaemonCacheRoot(fileManager: FileManager = .default) throws -> URL {
        // Cache under the non-TCC cmux state directory (matching the CLI's
        // remoteDaemonCacheURL) rather than Application Support, so the
        // separately-signed CLI can read it on `cmux ssh` without tripping the
        // macOS Sequoia "access data from other apps" prompt
        // (https://github.com/manaflow-ai/cmux/issues/5146).
        let cacheRoot = CmuxStateDirectory.url(homeDirectory: fileManager.homeDirectoryForCurrentUser)
            .appendingPathComponent("remote-daemons", isDirectory: true)
        try fileManager.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        return cacheRoot
    }

    static func remoteDaemonCachedBinaryURL(
        version: String,
        goOS: String,
        goArch: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        try remoteDaemonCacheRoot(fileManager: fileManager)
            .appendingPathComponent(version, isDirectory: true)
            .appendingPathComponent("\(goOS)-\(goArch)", isDirectory: true)
            .appendingPathComponent("cmuxd-remote", isDirectory: false)
    }

    private static func sha256Hex(forFile url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func allowLocalDaemonBuildFallback(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment["CMUX_REMOTE_DAEMON_ALLOW_LOCAL_BUILD"] == "1"
    }

    private static func explicitRemoteDaemonBinaryURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        guard allowLocalDaemonBuildFallback(environment: environment) else { return nil }
        guard let path = environment["CMUX_REMOTE_DAEMON_BINARY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: false).standardizedFileURL
    }

    private static func versionedRemoteDaemonBuildURL(goOS: String, goArch: String, version: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("cmux-remote-daemon-build", isDirectory: true)
            .appendingPathComponent(version, isDirectory: true)
            .appendingPathComponent("\(goOS)-\(goArch)", isDirectory: true)
            .appendingPathComponent("cmuxd-remote", isDirectory: false)
    }

    /// Fetch the live manifest JSON from the release, returning nil on any failure.
    private static func fetchRemoteManifestLocked(releaseURL: String, version: String) -> WorkspaceRemoteDaemonManifest? {
        guard let manifestURL = URL(string: "\(releaseURL)/cmuxd-remote-manifest.json") else { return nil }
        let request = NSMutableURLRequest(url: manifestURL)
        request.timeoutInterval = 15
        request.setValue("cmux/\(version)", forHTTPHeaderField: "User-Agent")
        let session = URLSession(configuration: .ephemeral)
        let semaphore = DispatchSemaphore(value: 0)
        var resultData: Data?
        session.dataTask(with: request as URLRequest) { data, response, error in
            defer { semaphore.signal() }
            guard error == nil,
                  let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else { return }
            resultData = data
        }.resume()
        _ = semaphore.wait(timeout: .now() + 20.0)
        session.finishTasksAndInvalidate()
        guard let data = resultData else { return nil }
        return try? JSONDecoder().decode(WorkspaceRemoteDaemonManifest.self, from: data)
    }

    private func downloadRemoteDaemonBinaryLocked(entry: WorkspaceRemoteDaemonManifest.Entry, version: String, releaseURL: String? = nil) throws -> URL {
        guard let url = URL(string: entry.downloadURL) else {
            throw NSError(domain: "cmux.remote.daemon", code: 25, userInfo: [
                NSLocalizedDescriptionKey: "remote daemon manifest has an invalid download URL",
            ])
        }

        let cacheURL = try Self.remoteDaemonCachedBinaryURL(version: version, goOS: entry.goOS, goArch: entry.goArch)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let request = NSMutableURLRequest(url: url)
        request.timeoutInterval = 60
        request.setValue("cmux/\(version)", forHTTPHeaderField: "User-Agent")
        let session = URLSession(configuration: .ephemeral)

        let semaphore = DispatchSemaphore(value: 0)
        var downloadedURL: URL?
        var downloadError: Error?
        session.downloadTask(with: request as URLRequest) { localURL, response, error in
            defer { semaphore.signal() }
            if let error {
                downloadError = error
                return
            }
            if let httpResponse = response as? HTTPURLResponse,
               !(200...299).contains(httpResponse.statusCode) {
                downloadError = NSError(domain: "cmux.remote.daemon", code: 26, userInfo: [
                    NSLocalizedDescriptionKey: "remote daemon download failed with HTTP \(httpResponse.statusCode)",
                ])
                return
            }
            downloadedURL = localURL
        }.resume()
        _ = semaphore.wait(timeout: .now() + 75.0)
        session.finishTasksAndInvalidate()

        if let downloadError {
            throw downloadError
        }
        guard let downloadedURL else {
            throw NSError(domain: "cmux.remote.daemon", code: 27, userInfo: [
                NSLocalizedDescriptionKey: "remote daemon download did not produce a file",
            ])
        }

        let downloadedSHA = try Self.sha256Hex(forFile: downloadedURL)
        if downloadedSHA != entry.sha256.lowercased() {
            // The embedded manifest's checksum doesn't match the downloaded binary.
            // This can happen when a newer nightly overwrites the shared release
            // asset after this build's manifest was embedded. As a fallback, fetch
            // the live manifest from the release and verify against that.
            if let releaseURL,
               let liveManifest = Self.fetchRemoteManifestLocked(releaseURL: releaseURL, version: version),
               let liveEntry = liveManifest.entry(goOS: entry.goOS, goArch: entry.goArch),
               downloadedSHA == liveEntry.sha256.lowercased() {
                debugLog("remote.download.checksum-fallback: embedded manifest checksum stale, live manifest matched for \(entry.assetName)")
            } else {
                throw NSError(domain: "cmux.remote.daemon", code: 28, userInfo: [
                    NSLocalizedDescriptionKey: "remote daemon checksum mismatch for \(entry.assetName)",
                ])
            }
        }

        let tempURL = cacheURL.deletingLastPathComponent()
            .appendingPathComponent(".\(cacheURL.lastPathComponent).tmp-\(UUID().uuidString)")
        try? fileManager.removeItem(at: tempURL)
        try fileManager.moveItem(at: downloadedURL, to: tempURL)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempURL.path)
        try? fileManager.removeItem(at: cacheURL)
        try fileManager.moveItem(at: tempURL, to: cacheURL)
        return cacheURL
    }

    private func buildLocalDaemonBinary(goOS: String, goArch: String, version: String) throws -> URL {
        if let explicitBinary = Self.explicitRemoteDaemonBinaryURL(),
           FileManager.default.isExecutableFile(atPath: explicitBinary.path) {
            debugLog("remote.build.explicit path=\(explicitBinary.path)")
            return explicitBinary
        }

        if let manifest = Self.remoteDaemonManifest(),
           manifest.appVersion == version,
           let entry = manifest.entry(goOS: goOS, goArch: goArch) {
            let cacheURL = try Self.remoteDaemonCachedBinaryURL(version: manifest.appVersion, goOS: goOS, goArch: goArch)
            if FileManager.default.fileExists(atPath: cacheURL.path) {
                let cachedSHA = try Self.sha256Hex(forFile: cacheURL)
                if cachedSHA == entry.sha256.lowercased(),
                   FileManager.default.isExecutableFile(atPath: cacheURL.path) {
                    debugLog("remote.build.cached path=\(cacheURL.path)")
                    return cacheURL
                }
                try? FileManager.default.removeItem(at: cacheURL)
            }
            let downloadedURL = try downloadRemoteDaemonBinaryLocked(entry: entry, version: manifest.appVersion, releaseURL: manifest.releaseURL)
            debugLog("remote.build.downloaded path=\(downloadedURL.path)")
            return downloadedURL
        }

        guard Self.allowLocalDaemonBuildFallback() else {
            throw NSError(domain: "cmux.remote.daemon", code: 20, userInfo: [
                NSLocalizedDescriptionKey: "this build does not include a verified cmuxd-remote manifest for \(goOS)-\(goArch). Use a release/nightly build, or set CMUX_REMOTE_DAEMON_ALLOW_LOCAL_BUILD=1 for a dev-only fallback.",
            ])
        }

        guard let repoRoot = Self.findRepoRoot() else {
            throw NSError(domain: "cmux.remote.daemon", code: 20, userInfo: [
                NSLocalizedDescriptionKey: "cannot locate cmux repo root for dev-only cmuxd-remote build fallback",
            ])
        }
        let daemonRoot = repoRoot.appendingPathComponent("daemon/remote", isDirectory: true)
        let goModPath = daemonRoot.appendingPathComponent("go.mod").path
        guard FileManager.default.fileExists(atPath: goModPath) else {
            throw NSError(domain: "cmux.remote.daemon", code: 21, userInfo: [
                NSLocalizedDescriptionKey: "missing daemon module at \(goModPath)",
            ])
        }
        guard let goBinary = Self.which("go") else {
            throw NSError(domain: "cmux.remote.daemon", code: 22, userInfo: [
                NSLocalizedDescriptionKey: "go is required for the dev-only cmuxd-remote build fallback",
            ])
        }

        let output = Self.versionedRemoteDaemonBuildURL(goOS: goOS, goArch: goArch, version: version)
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)

        var env = ProcessInfo.processInfo.environment
        env["GOOS"] = goOS
        env["GOARCH"] = goArch
        env["CGO_ENABLED"] = "0"
        let ldflags = "-s -w -X main.version=\(version)"
        let result = try runProcess(
            executable: goBinary,
            arguments: ["build", "-trimpath", "-buildvcs=false", "-ldflags", ldflags, "-o", output.path, "./cmd/cmuxd-remote"],
            environment: env,
            currentDirectory: daemonRoot,
            stdin: nil,
            timeout: 90
        )
        guard result.status == 0 else {
            let detail = Self.bestErrorLine(stderr: result.stderr, stdout: result.stdout) ?? "go build failed with status \(result.status)"
            throw NSError(domain: "cmux.remote.daemon", code: 23, userInfo: [
                NSLocalizedDescriptionKey: "failed to build cmuxd-remote: \(detail)",
            ])
        }
        guard FileManager.default.isExecutableFile(atPath: output.path) else {
            throw NSError(domain: "cmux.remote.daemon", code: 24, userInfo: [
                NSLocalizedDescriptionKey: "cmuxd-remote build output is not executable",
            ])
        }
        debugLog("remote.build.output path=\(output.path)")
        return output
    }

    private func uploadRemoteDaemonBinaryLocked(localBinary: URL, location: RemoteDaemonInstallLocation) throws {
        let remotePath = location.absolutePath
        let remoteDirectory = location.directory
        let remoteTempPath = "\(remotePath).tmp-\(UUID().uuidString.prefix(8))"
        debugLog(
            "remote.upload.begin local=\(localBinary.path) remoteTemp=\(remoteTempPath) remote=\(remotePath)"
        )

        let mkdirScript = "mkdir -p \(Self.shellSingleQuoted(remoteDirectory))"
        let mkdirCommand = "sh -c \(Self.shellSingleQuoted(mkdirScript))"
        let mkdirResult = try sshExec(arguments: sshCommonArguments(batchMode: true) + [configuration.destination, mkdirCommand], timeout: 12)
        guard mkdirResult.status == 0 else {
            let detail = Self.bestErrorLine(stderr: mkdirResult.stderr, stdout: mkdirResult.stdout) ?? "ssh exited \(mkdirResult.status)"
            throw NSError(domain: "cmux.remote.daemon", code: 30, userInfo: [
                NSLocalizedDescriptionKey: "failed to create remote daemon directory: \(detail)",
            ])
        }

        let scpSSHOptions = backgroundSSHOptions(configuration.sshOptions)
        var scpArgs: [String] = ["-q"]
        if !hasSSHOptionKey(scpSSHOptions, key: "StrictHostKeyChecking") {
            scpArgs += ["-o", "StrictHostKeyChecking=accept-new"]
        }
        scpArgs += ["-o", "ControlMaster=no"]
        if let port = configuration.port {
            scpArgs += ["-P", String(port)]
        }
        if let identityFile = configuration.identityFile,
           !identityFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            scpArgs += ["-i", identityFile]
        }
        for option in scpSSHOptions {
            scpArgs += ["-o", option]
        }
        scpArgs += [localBinary.path, "\(configuration.destination):\(remoteTempPath)"]
        let scpResult = try scpExec(arguments: scpArgs, timeout: 45)
        guard scpResult.status == 0 else {
            let detail = Self.bestErrorLine(stderr: scpResult.stderr, stdout: scpResult.stdout) ?? "scp exited \(scpResult.status)"
            throw NSError(domain: "cmux.remote.daemon", code: 31, userInfo: [
                NSLocalizedDescriptionKey: "failed to upload cmuxd-remote: \(detail)",
            ])
        }

        let finalizeScript = """
        chmod 755 \(Self.shellSingleQuoted(remoteTempPath)) && \
        mv \(Self.shellSingleQuoted(remoteTempPath)) \(Self.shellSingleQuoted(remotePath))
        """
        let finalizeCommand = "sh -c \(Self.shellSingleQuoted(finalizeScript))"
        let finalizeResult = try sshExec(arguments: sshCommonArguments(batchMode: true) + [configuration.destination, finalizeCommand], timeout: 12)
        guard finalizeResult.status == 0 else {
            let detail = Self.bestErrorLine(stderr: finalizeResult.stderr, stdout: finalizeResult.stdout) ?? "ssh exited \(finalizeResult.status)"
            throw NSError(domain: "cmux.remote.daemon", code: 32, userInfo: [
                NSLocalizedDescriptionKey: "failed to install remote daemon binary: \(detail)",
            ])
        }
    }

    private func helloRemoteDaemonLocked(remotePath: String) throws -> DaemonHello {
        let request = #"{"id":1,"method":"hello","params":{}}"#
        let script = "printf '%s\\n' \(Self.shellSingleQuoted(request)) | \(Self.shellSingleQuoted(remotePath)) serve --stdio"
        let command = "sh -c \(Self.shellSingleQuoted(script))"
        let result = try sshExec(arguments: sshCommonArguments(batchMode: true) + [configuration.destination, command], timeout: 12)
        guard result.status == 0 else {
            let detail = Self.bestErrorLine(stderr: result.stderr, stdout: result.stdout) ?? "ssh exited \(result.status)"
            throw NSError(domain: "cmux.remote.daemon", code: 40, userInfo: [
                NSLocalizedDescriptionKey: "failed to start remote daemon: \(detail)",
            ])
        }

        let responseLine = result.stdout
            .split(separator: "\n")
            .map(String.init)
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? ""
        guard !responseLine.isEmpty,
              let data = responseLine.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            throw NSError(domain: "cmux.remote.daemon", code: 41, userInfo: [
                NSLocalizedDescriptionKey: "remote daemon hello returned invalid JSON",
            ])
        }

        if let ok = payload["ok"] as? Bool, !ok {
            let errorMessage: String = {
                if let errorObject = payload["error"] as? [String: Any],
                   let message = errorObject["message"] as? String,
                   !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return message
                }
                return "hello call failed"
            }()
            throw NSError(domain: "cmux.remote.daemon", code: 42, userInfo: [
                NSLocalizedDescriptionKey: "remote daemon hello failed: \(errorMessage)",
            ])
        }

        let resultObject = payload["result"] as? [String: Any] ?? [:]
        let name = (resultObject["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let version = (resultObject["version"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let capabilities = (resultObject["capabilities"] as? [String]) ?? []
        return DaemonHello(
            name: (name?.isEmpty == false ? name! : "cmuxd-remote"),
            version: (version?.isEmpty == false ? version! : "dev"),
            capabilities: capabilities,
            remotePath: remotePath
        )
    }

    private static func mapUnameOS(_ raw: String) -> String? {
        switch raw.lowercased() {
        case "linux":
            return "linux"
        case "darwin":
            return "darwin"
        case "freebsd":
            return "freebsd"
        default:
            return nil
        }
    }

    private static func mapUnameArch(_ raw: String) -> String? {
        switch raw.lowercased() {
        case "x86_64", "amd64":
            return "amd64"
        case "aarch64", "arm64":
            return "arm64"
        case "armv7l":
            return "arm"
        default:
            return nil
        }
    }

    private static func remoteDaemonVersion() -> String {
        let bundleVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let baseVersion = (bundleVersion?.isEmpty == false) ? bundleVersion! : "dev"
        guard allowLocalDaemonBuildFallback(),
              let sourceFingerprint = remoteDaemonSourceFingerprint(),
              !sourceFingerprint.isEmpty else {
            return baseVersion
        }
        return "\(baseVersion)-dev-\(sourceFingerprint)"
    }

    private static let cachedRemoteDaemonSourceFingerprint: String? = computeRemoteDaemonSourceFingerprint()

    private static func remoteDaemonSourceFingerprint() -> String? {
        cachedRemoteDaemonSourceFingerprint
    }

    private static func computeRemoteDaemonSourceFingerprint(fileManager: FileManager = .default) -> String? {
        guard let repoRoot = findRepoRoot() else { return nil }
        let daemonRoot = repoRoot.appendingPathComponent("daemon/remote", isDirectory: true)
        guard let enumerator = fileManager.enumerator(
            at: daemonRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        var relativePaths: [String] = []
        for case let fileURL as URL in enumerator {
            guard let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                  resourceValues.isRegularFile == true else {
                continue
            }

            let relativePath = fileURL.path.replacingOccurrences(of: daemonRoot.path + "/", with: "")
            if relativePath == "go.mod" || relativePath == "go.sum" || relativePath.hasSuffix(".go") {
                relativePaths.append(relativePath)
            }
        }

        guard !relativePaths.isEmpty else { return nil }

        let digest = SHA256.hash(data: relativePaths.sorted().reduce(into: Data()) { partialResult, relativePath in
            let fileURL = daemonRoot.appendingPathComponent(relativePath, isDirectory: false)
            guard let fileData = try? Data(contentsOf: fileURL) else { return }
            partialResult.append(Data(relativePath.utf8))
            partialResult.append(0)
            partialResult.append(fileData)
            partialResult.append(0)
        })
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(12))
    }

    private static func remoteDaemonPath(version: String, goOS: String, goArch: String) -> String {
        ".cmux/bin/cmuxd-remote/\(version)/\(goOS)-\(goArch)/cmuxd-remote"
    }

    private static func remoteDaemonInstallLocation(
        version: String,
        goOS: String,
        goArch: String,
        homeDirectory: String
    ) throws -> RemoteDaemonInstallLocation {
        let relativePath = remoteDaemonPath(version: version, goOS: goOS, goArch: goArch)
        let absolutePath = try absoluteRemotePath(homeDirectory: homeDirectory, relativePath: relativePath)
        return RemoteDaemonInstallLocation(relativePath: relativePath, absolutePath: absolutePath)
    }

    private static func absoluteRemotePath(homeDirectory: String, relativePath: String) throws -> String {
        var normalizedHome = homeDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedRelative = relativePath
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .drop(while: { $0 == "/" })
        guard normalizedHome.hasPrefix("/"), !normalizedHome.isEmpty, !normalizedRelative.isEmpty else {
            throw NSError(domain: "cmux.remote.daemon", code: 14, userInfo: [
                NSLocalizedDescriptionKey: "remote daemon install path could not be resolved from remote HOME",
            ])
        }
        while normalizedHome.count > 1, normalizedHome.hasSuffix("/") {
            normalizedHome.removeLast()
        }
        if normalizedHome == "/" {
            return "/" + String(normalizedRelative)
        }
        return normalizedHome + "/" + String(normalizedRelative)
    }

    static func remoteDaemonPathShellExpression(_ remotePath: String) -> String {
        let trimmedRemotePath = remotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedRemotePath.hasPrefix("/") {
            return shellSingleQuoted(trimmedRemotePath)
        }
        return "\"$HOME/\(trimmedRemotePath)\""
    }

}
