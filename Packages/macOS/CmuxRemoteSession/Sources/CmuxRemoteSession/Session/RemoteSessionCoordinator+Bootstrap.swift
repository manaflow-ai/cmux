internal import CmuxCore
internal import CmuxFoundation
internal import CryptoKit
public import Foundation

// cmuxd-remote bootstrap: probe the remote platform and existing install,
// acquire a binary (explicit override, verified manifest download, or the
// dev-only local `go build` fallback), upload + install it atomically, and
// perform the stdio `hello` handshake. Faithful lift: probe/upload/install
// script text, the hello request line, every NSError domain/code/message,
// and the reinstall-on-missing-capability flow are pinned legacy behavior.
// `Bundle.main` reads ride the injected ``RemoteSessionBuildInfoProviding``.
extension RemoteSessionCoordinator {
    static let remotePlatformProbeHomeMarker = "__CMUX_REMOTE_HOME__="
    static let remotePlatformProbeOSMarker = "__CMUX_REMOTE_OS__="
    static let remotePlatformProbeArchMarker = "__CMUX_REMOTE_ARCH__="
    static let remotePlatformProbeExistsMarker = "__CMUX_REMOTE_EXISTS__="

    func bootstrapDaemonLocked(requiredCapabilities: [String]) throws -> DaemonHello {
        debugLog("remote.bootstrap.begin \(debugConfigSummary())")
        let version = remoteDaemonVersion()
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

    func bootstrapLocalDaemonLocked(requiredCapabilities: [String]) throws -> DaemonHello {
        debugLog("remote.bootstrap.local.begin \(debugConfigSummary())")
        let version = remoteDaemonVersion()
        let localBinary = try buildLocalDaemonBinary(
            goOS: "darwin",
            goArch: Self.localDaemonGoArch(),
            version: version
        )
        let hello = try helloLocalDaemonLocked(localPath: localBinary.path)
        let missingCapabilities = Self.missingRequiredCapabilities(requiredCapabilities, in: hello.capabilities)
        guard missingCapabilities.isEmpty else {
            throw NSError(domain: "cmux.remote.daemon", code: 44, userInfo: [
                NSLocalizedDescriptionKey: daemonStrings.missingRequiredCapabilitiesMessage(missingCapabilities),
                NSDebugDescriptionErrorKey: "local daemon missing required capability \(missingCapabilities.joined(separator: ","))",
            ])
        }
        debugLog(
            "remote.bootstrap.local.ready name=\(hello.name) version=\(hello.version) " +
            "capabilities=\(hello.capabilities.joined(separator: ",")) path=\(hello.remotePath)"
        )
        return hello
    }

    /// Builds the remote shell probe that reports platform and daemon availability markers.
    ///
    /// The OS/arch normalization uses literal `case` alternatives rather than
    /// `tr '[:upper:]' '[:lower:]'` so the probe stays correct on OpenWrt
    /// BusyBox builds compiled without `FEATURE_TR_CLASSES` (where the class
    /// arguments are mapped positionally and corrupt the value). The version
    /// segment is sanitized before interpolation to keep it shell-safe.
    static func remotePlatformProbeScript(version: String) -> String {
        let scriptVersion = normalizedRemotePlatformProbeVersion(version)
        return """
        cmux_uname_os="$(uname -s)"
        cmux_uname_arch="$(uname -m)"
        printf '%s%s\\n' '\(Self.remotePlatformProbeHomeMarker)' "$HOME"
        printf '%s%s\\n' '\(Self.remotePlatformProbeOSMarker)' "$cmux_uname_os"
        printf '%s%s\\n' '\(Self.remotePlatformProbeArchMarker)' "$cmux_uname_arch"
        case "$cmux_uname_os" in
          Linux|linux|LINUX) cmux_go_os=linux ;;
          Darwin|darwin|DARWIN) cmux_go_os=darwin ;;
          FreeBSD|freebsd|FREEBSD) cmux_go_os=freebsd ;;
          *) exit 70 ;;
        esac
        case "$cmux_uname_arch" in
          x86_64|X86_64|amd64|AMD64) cmux_go_arch=amd64 ;;
          aarch64|AARCH64|arm64|ARM64) cmux_go_arch=arm64 ;;
          armv7l|ARMV7L|armv7|ARMV7) cmux_go_arch=arm ;;
          *) exit 71 ;;
        esac
        cmux_remote_path="$HOME/.cmux/bin/cmuxd-remote/\(scriptVersion)/${cmux_go_os}-${cmux_go_arch}/cmuxd-remote"
        if [ -x "$cmux_remote_path" ]; then
          printf '%syes\\n' '\(Self.remotePlatformProbeExistsMarker)'
        else
          printf '%sno\\n' '\(Self.remotePlatformProbeExistsMarker)'
        fi
        """
    }

    /// Returns stdout suitable for user-facing error details by removing internal probe markers.
    static func remotePlatformProbeUserFacingStdout(_ stdout: String) -> String {
        stdout
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !isRemotePlatformProbeMarkerLine(String($0).trimmingCharacters(in: .whitespacesAndNewlines)) }
            .joined(separator: "\n")
    }

    /// Normalizes the daemon version path segment before it is interpolated into remote shell.
    static func normalizedRemotePlatformProbeVersion(_ version: String) -> String {
        guard !version.isEmpty,
              version.count <= 128,
              version != ".",
              version != ".." else {
            return "dev"
        }
        let isSafePathSegment = version.utf8.allSatisfy { byte in
            (byte >= 65 && byte <= 90) ||
                (byte >= 97 && byte <= 122) ||
                (byte >= 48 && byte <= 57) ||
                byte == 45 ||
                byte == 46 ||
                byte == 95
        }
        return isSafePathSegment ? version : "dev"
    }

    /// Returns true when a line is one of the internal markers emitted by the probe.
    static func isRemotePlatformProbeMarkerLine(_ line: String) -> Bool {
        line.hasPrefix(remotePlatformProbeHomeMarker) ||
            line.hasPrefix(remotePlatformProbeOSMarker) ||
            line.hasPrefix(remotePlatformProbeArchMarker) ||
            line.hasPrefix(remotePlatformProbeExistsMarker)
    }

    func probeRemoteBootstrapStateLocked(version: String) throws -> RemoteBootstrapState {
        let script = Self.remotePlatformProbeScript(version: version)
        let command = "sh -c \(script.shellSingleQuoted)"
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
        let userFacingStdout = Self.remotePlatformProbeUserFacingStdout(result.stdout)
        guard let unameOS, let unameArch, let homeDirectory else {
            let detail = Self.bestErrorLine(stderr: result.stderr, stdout: userFacingStdout) ?? "ssh exited \(result.status)"
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
            let detail = Self.bestErrorLine(stderr: result.stderr, stdout: userFacingStdout) ?? "ssh exited \(result.status)"
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

    static func allowLocalDaemonBuildFallback(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment["CMUX_REMOTE_DAEMON_ALLOW_LOCAL_BUILD"] == "1"
    }

    static func explicitRemoteDaemonBinaryURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        guard allowLocalDaemonBuildFallback(environment: environment) else { return nil }
        guard let path = environment["CMUX_REMOTE_DAEMON_BINARY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: false).standardizedFileURL
    }

    static func versionedRemoteDaemonBuildURL(goOS: String, goArch: String, version: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("cmux-remote-daemon-build", isDirectory: true)
            .appendingPathComponent(version, isDirectory: true)
            .appendingPathComponent("\(goOS)-\(goArch)", isDirectory: true)
            .appendingPathComponent("cmuxd-remote", isDirectory: false)
    }

    func buildLocalDaemonBinary(goOS: String, goArch: String, version: String) throws -> URL {
        if let explicitBinary = Self.explicitRemoteDaemonBinaryURL(),
           FileManager.default.isExecutableFile(atPath: explicitBinary.path) {
            debugLog("remote.build.explicit path=\(explicitBinary.path)")
            return explicitBinary
        }

        if let manifest = buildInfo.embeddedDaemonManifest(),
           manifest.appVersion == version,
           let entry = manifest.entry(goOS: goOS, goArch: goArch) {
            if let cacheURL = try manifestRepository.validatedCachedBinary(entry: entry, version: manifest.appVersion) {
                debugLog("remote.build.cached path=\(cacheURL.path)")
                return cacheURL
            }
            let download = try manifestRepository.downloadBinary(
                entry: entry,
                version: manifest.appVersion,
                releaseURL: manifest.releaseURL
            )
            if download.usedLiveManifestChecksumFallback {
                debugLog("remote.download.checksum-fallback: embedded manifest checksum stale, live manifest matched for \(entry.assetName)")
            }
            debugLog("remote.build.downloaded path=\(download.binaryURL.path)")
            return download.binaryURL
        }

        guard Self.allowLocalDaemonBuildFallback() else {
            throw NSError(domain: "cmux.remote.daemon", code: 20, userInfo: [
                NSLocalizedDescriptionKey: "this build does not include a verified cmuxd-remote manifest for \(goOS)-\(goArch). Use a release/nightly build, or set CMUX_REMOTE_DAEMON_ALLOW_LOCAL_BUILD=1 for a dev-only fallback.",
            ])
        }

        guard let repoRoot = findRepoRoot() else {
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

    func uploadRemoteDaemonBinaryLocked(localBinary: URL, location: RemoteDaemonInstallLocation) throws {
        let remotePath = location.absolutePath
        let remoteDirectory = location.directory
        let remoteTempPath = "\(remotePath).tmp-\(UUID().uuidString.prefix(8))"
        debugLog(
            "remote.upload.begin local=\(localBinary.path) remoteTemp=\(remoteTempPath) remote=\(remotePath)"
        )

        let mkdirScript = "mkdir -p \(remoteDirectory.shellSingleQuoted)"
        let mkdirCommand = "sh -c \(mkdirScript.shellSingleQuoted)"
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
        chmod 755 \(remoteTempPath.shellSingleQuoted) && \
        mv \(remoteTempPath.shellSingleQuoted) \(remotePath.shellSingleQuoted)
        """
        let finalizeCommand = "sh -c \(finalizeScript.shellSingleQuoted)"
        let finalizeResult = try sshExec(arguments: sshCommonArguments(batchMode: true) + [configuration.destination, finalizeCommand], timeout: 12)
        guard finalizeResult.status == 0 else {
            let detail = Self.bestErrorLine(stderr: finalizeResult.stderr, stdout: finalizeResult.stdout) ?? "ssh exited \(finalizeResult.status)"
            throw NSError(domain: "cmux.remote.daemon", code: 32, userInfo: [
                NSLocalizedDescriptionKey: "failed to install remote daemon binary: \(detail)",
            ])
        }
    }

    func helloRemoteDaemonLocked(remotePath: String) throws -> DaemonHello {
        let request = #"{"id":1,"method":"hello","params":{}}"#
        let script = "printf '%s\\n' \(request.shellSingleQuoted) | \(remotePath.shellSingleQuoted) serve --stdio"
        let command = "sh -c \(script.shellSingleQuoted)"
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

    func helloLocalDaemonLocked(localPath: String) throws -> DaemonHello {
        let request = #"{"id":1,"method":"hello","params":{}}"# + "\n"
        let result = try runProcess(
            executable: localPath,
            arguments: ["serve", "--stdio"],
            stdin: Data(request.utf8),
            timeout: 12
        )
        guard result.status == 0 else {
            let detail = Self.bestErrorLine(stderr: result.stderr, stdout: result.stdout) ?? "local daemon exited \(result.status)"
            throw NSError(domain: "cmux.remote.daemon", code: 45, userInfo: [
                NSLocalizedDescriptionKey: "failed to start local daemon: \(detail)",
            ])
        }
        let responseLine = result.stdout
            .split(separator: "\n")
            .map(String.init)
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? ""
        guard !responseLine.isEmpty,
              let data = responseLine.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            throw NSError(domain: "cmux.remote.daemon", code: 46, userInfo: [
                NSLocalizedDescriptionKey: "local daemon hello returned invalid JSON",
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
            throw NSError(domain: "cmux.remote.daemon", code: 47, userInfo: [
                NSLocalizedDescriptionKey: "local daemon hello failed: \(errorMessage)",
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
            remotePath: localPath
        )
    }

    static func localDaemonGoArch() -> String {
    #if arch(arm64)
        return "arm64"
    #elseif arch(x86_64)
        return "amd64"
    #else
        return "arm64"
    #endif
    }

    static func mapUnameOS(_ raw: String) -> String? {
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

    static func mapUnameArch(_ raw: String) -> String? {
        switch raw.lowercased() {
        case "x86_64", "amd64":
            return "amd64"
        case "aarch64", "arm64":
            return "arm64"
        case "armv7l", "armv7":
            return "arm"
        default:
            return nil
        }
    }

    func remoteDaemonVersion() -> String {
        let bundleVersion = buildInfo.appVersion()?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let baseVersion = (bundleVersion?.isEmpty == false) ? bundleVersion! : "dev"
        guard Self.allowLocalDaemonBuildFallback(),
              let sourceFingerprint = remoteDaemonSourceFingerprint(),
              !sourceFingerprint.isEmpty else {
            return baseVersion
        }
        return "\(baseVersion)-dev-\(sourceFingerprint)"
    }

    // Queue-confined per-coordinator cache of the dev-only source
    // fingerprint (the legacy process-wide `static let` cache; per-instance
    // recompute only happens on reconnect with the dev fallback enabled).
    // `.none` = not computed yet; `.some(nil)` = computed, unavailable.
    private func remoteDaemonSourceFingerprint() -> String? {
        if let cached = remoteDaemonSourceFingerprintCache {
            return cached
        }
        let computed = computeRemoteDaemonSourceFingerprint()
        remoteDaemonSourceFingerprintCache = .some(computed)
        return computed
    }

    private func computeRemoteDaemonSourceFingerprint(fileManager: FileManager = .default) -> String? {
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

    static func remoteDaemonPath(version: String, goOS: String, goArch: String) -> String {
        ".cmux/bin/cmuxd-remote/\(version)/\(goOS)-\(goArch)/cmuxd-remote"
    }

    static func remoteDaemonInstallLocation(
        version: String,
        goOS: String,
        goArch: String,
        homeDirectory: String
    ) throws -> RemoteDaemonInstallLocation {
        let relativePath = remoteDaemonPath(version: version, goOS: goOS, goArch: goArch)
        let absolutePath = try absoluteRemotePath(homeDirectory: homeDirectory, relativePath: relativePath)
        return RemoteDaemonInstallLocation(relativePath: relativePath, absolutePath: absolutePath)
    }

    static func absoluteRemotePath(homeDirectory: String, relativePath: String) throws -> String {
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

    /// Ordered executable search paths for the dev-only `go` lookup: `$PATH`,
    /// home-relative bins, `path_helper` output, then the standard system
    /// directories, deduplicated in order. Static and pinned by tests.
    public static func executableSearchPaths(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        pathHelperOutput: String? = nil
    ) -> [String] {
        var ordered: [String] = []
        var seen: Set<String> = []

        func appendSearchPath(_ rawPath: String?) {
            guard let rawPath else { return }
            let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            guard seen.insert(trimmed).inserted else { return }
            ordered.append(trimmed)
        }

        if let path = environment["PATH"] {
            for component in path.split(separator: ":") {
                appendSearchPath(String(component))
            }
        }

        if let home = environment["HOME"], !home.isEmpty {
            appendSearchPath((home as NSString).appendingPathComponent(".local/bin"))
            appendSearchPath((home as NSString).appendingPathComponent("go/bin"))
            appendSearchPath((home as NSString).appendingPathComponent("bin"))
        }

        let helperOutput = pathHelperOutput ?? pathHelperShellOutput()
        for component in parsePathHelperPaths(helperOutput) {
            appendSearchPath(component)
        }

        for component in [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ] {
            appendSearchPath(component)
        }

        return ordered
    }

    /// Extracts the colon-separated PATH entries from `path_helper -s`
    /// output, ignoring MANPATH assignments. Static and pinned by tests.
    public static func parsePathHelperPaths(_ output: String) -> [String] {
        for fragment in output.split(whereSeparator: { $0 == "\n" || $0 == ";" }) {
            let trimmed = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("PATH=\"") else { continue }
            let suffix = trimmed.dropFirst("PATH=\"".count)
            guard let closingQuote = suffix.firstIndex(of: "\"") else { return [] }
            return suffix[..<closingQuote]
                .split(separator: ":")
                .map(String.init)
        }
        return []
    }

    private static func pathHelperShellOutput() -> String {
        let executable = "/usr/libexec/path_helper"
        guard FileManager.default.isExecutableFile(atPath: executable) else { return "" }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-s"]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            return ""
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return "" }
        let data = stdout.fileHandleForReading.readDataToEndOfFileOrEmpty()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func which(_ executable: String) -> String? {
        for component in executableSearchPaths() {
            let candidate = (component as NSString).appendingPathComponent(executable)
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    func findRepoRoot() -> URL? {
        var candidates: [URL] = []
        // Compile-time path of this package source; the marker walk below
        // still lands on the checkout root (dev-only fallback path).
        let compileTimeRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Session
            .deletingLastPathComponent() // CmuxRemoteSession
        candidates.append(compileTimeRoot)
        let environment = ProcessInfo.processInfo.environment
        if let envRoot = environment["CMUX_REMOTE_DAEMON_SOURCE_ROOT"],
           !envRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            candidates.append(URL(fileURLWithPath: envRoot, isDirectory: true))
        }
        if let envRoot = environment["CMUXTERM_REPO_ROOT"],
           !envRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            candidates.append(URL(fileURLWithPath: envRoot, isDirectory: true))
        }
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))
        if let executable = buildInfo.executableDirectoryURL() {
            candidates.append(executable)
            candidates.append(executable.deletingLastPathComponent())
            candidates.append(executable.deletingLastPathComponent().deletingLastPathComponent())
        }

        let fm = FileManager.default
        for base in candidates {
            var cursor = base.standardizedFileURL
            for _ in 0..<10 {
                let marker = cursor.appendingPathComponent("daemon/remote/go.mod").path
                if fm.fileExists(atPath: marker) {
                    return cursor
                }
                let parent = cursor.deletingLastPathComponent()
                if parent.path == cursor.path {
                    break
                }
                cursor = parent
            }
        }
        return nil
    }
}
