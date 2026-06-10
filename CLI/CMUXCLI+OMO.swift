import Foundation
import CMUXAgentLaunch
import CmuxFoundation
import CmuxSocketControl
import CoreFoundation
import CryptoKit
import Darwin
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
#if canImport(Security)
import Security
#endif
#if canImport(Sentry)
import Sentry
#endif


// MARK: - cmux omo launcher
extension CMUXCLI {
    private func resolveOpenCodeExecutable(searchPath: String?) -> String? {
        resolveExecutableInSearchPath("opencode", searchPath: searchPath)
    }

    private func createOMOShimDirectory() throws -> URL {
        // tmux shim: redirects tmux commands to cmux __tmux-compat
        // Handle -V locally (no socket needed) since __tmux-compat requires a connection.
        let tmuxScript = """
        #!/usr/bin/env bash
        set -euo pipefail
        # Only match -V/-v as the first arg (top-level tmux flag).
        # -v inside subcommands (e.g. split-window -v) is a vertical split flag.
        case "${1:-}" in
          -V|-v) echo "tmux 3.4"; exit 0 ;;
        esac
        exec "${CMUX_OMO_CMUX_BIN:-cmux}" __tmux-compat "$@"
        """
        let root = try createTmuxCompatShimDirectory(
            directoryName: "omo-bin",
            tmuxShimScript: tmuxScript
        )

        // terminal-notifier shim: intercepts macOS notifications and routes to cmux notify
        let notifierURL = root.appendingPathComponent("terminal-notifier", isDirectory: false)
        let notifierScript = """
        #!/usr/bin/env bash
        # Intercept terminal-notifier calls and route through cmux notify.
        # oh-my-openagent calls: terminal-notifier -title <t> -message <m> [-activate <id>]
        TITLE="" BODY=""
        while [[ $# -gt 0 ]]; do
          case "$1" in
            -title)   TITLE="$2"; shift 2 ;;
            -message) BODY="$2"; shift 2 ;;
            *)        shift ;;
          esac
        done
        exec "${CMUX_OMO_CMUX_BIN:-cmux}" notify --title "${TITLE:-OpenCode}" --body "${BODY:-}"
        """
        try writeShimIfChanged(notifierScript, to: notifierURL)

        return root
    }

    func writeShimIfChanged(_ script: String, to url: URL) throws {
        let normalized = script.trimmingCharacters(in: .whitespacesAndNewlines)
        let fileManager = FileManager.default
        let existing = try? String(contentsOf: url, encoding: .utf8)
        guard existing?.trimmingCharacters(in: .whitespacesAndNewlines) != normalized else {
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return
        }
        let directoryURL = url.deletingLastPathComponent()
        let tempURL = directoryURL.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try script.write(to: tempURL, atomically: false, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempURL.path)
        do {
            if fileManager.fileExists(atPath: url.path) {
                _ = try fileManager.replaceItemAt(url, withItemAt: tempURL)
            } else {
                try fileManager.moveItem(at: tempURL, to: url)
            }
        } catch {
            let current = try? String(contentsOf: url, encoding: .utf8)
            if current?.trimmingCharacters(in: .whitespacesAndNewlines) == normalized {
                try? fileManager.removeItem(at: tempURL)
                return
            }
            if fileManager.fileExists(atPath: url.path) {
                do {
                    _ = try fileManager.replaceItemAt(url, withItemAt: tempURL)
                    return
                } catch {}
            }
            try? fileManager.removeItem(at: tempURL)
            throw error
        }
    }

    static let omoPluginName = "oh-my-openagent"
    static let legacyOmoPluginName = "oh-my-opencode"
    static let openCodeSessionPluginConfigSpec = "./plugins/cmux-session.js"

    func resolveExecutableInPath(_ name: String, searchPath: String? = nil) -> String? {
        let entries = (searchPath ?? ProcessInfo.processInfo.environment["PATH"])?
            .split(separator: ":")
            .map(String.init) ?? []
        for entry in entries where !entry.isEmpty {
            let candidate = URL(fileURLWithPath: entry, isDirectory: true)
                .appendingPathComponent(name, isDirectory: false)
                .path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private func omoUserConfigDir() -> URL {
        let homePath = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        return URL(fileURLWithPath: homePath, isDirectory: true)
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("opencode", isDirectory: true)
    }

    private func omoShadowConfigDir() -> URL {
        let homePath = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        return URL(fileURLWithPath: homePath, isDirectory: true)
            .appendingPathComponent(".cmuxterm", isDirectory: true)
            .appendingPathComponent("omo-config", isDirectory: true)
    }

    private func omoFileType(at url: URL) -> FileAttributeType? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attrs?[.type] as? FileAttributeType
    }

    private func omoEnsureShadowPackageManifest(at shadowPackageURL: URL) throws {
        let fm = FileManager.default
        if omoFileType(at: shadowPackageURL) == .typeSymbolicLink {
            try? fm.removeItem(at: shadowPackageURL)
        }

        // Keep the shadow package isolated from stale/yanked pins in the user's
        // opencode package.json. bun will update this manifest with the resolved
        // oh-my-openagent version when installation succeeds.
        let packageManifest: [String: Any] = [
            "dependencies": [
                Self.omoPluginName: "latest"
            ],
            "name": "cmux-omo-shadow",
            "private": true
        ]
        let output = try JSONSerialization.data(withJSONObject: packageManifest, options: [.prettyPrinted, .sortedKeys])
        let existing = try? Data(contentsOf: shadowPackageURL)
        if existing != output {
            try output.write(to: shadowPackageURL, options: .atomic)
        }
    }

    private func omoEnsureShadowNodeModulesSymlink(
        shadowNodeModules: URL,
        userNodeModules: URL
    ) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: userNodeModules.path) else { return }

        if let type = omoFileType(at: shadowNodeModules) {
            if type == .typeSymbolicLink {
                let target = try? fm.destinationOfSymbolicLink(atPath: shadowNodeModules.path)
                if target != userNodeModules.path {
                    try? fm.removeItem(at: shadowNodeModules)
                } else {
                    return
                }
            } else {
                return
            }
        }

        if !fm.fileExists(atPath: shadowNodeModules.path) {
            try fm.createSymbolicLink(at: shadowNodeModules, withDestinationURL: userNodeModules)
        }
    }

    private func omoRunPackageInstall(
        executablePath: String,
        arguments: [String],
        currentDirectoryURL: URL,
        environment: [String: String]
    ) throws -> Int32 {
        let process = Process()
        process.currentDirectoryURL = currentDirectoryURL
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = FileHandle.standardError
        process.standardError = FileHandle.standardError
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private static func omoInstallingPluginMessage() -> String {
        String(localized: "cli.omo.installingPlugin", defaultValue: "Installing \(Self.omoPluginName) plugin (this may take a minute on first run)...")
    }

    private static func omoRetryingInstallMessage() -> String {
        String(localized: "cli.omo.retryingInstallCleanState", defaultValue: "Retrying \(Self.omoPluginName) install with a clean shadow package state...")
    }

    private static func omoInstallFailedMessage() -> String {
        String(localized: "cli.omo.installFailed", defaultValue: "Failed to install \(Self.omoPluginName). Try manually: npm install -g \(Self.omoPluginName)")
    }

    private static func omoNoPackageManagerMessage() -> String {
        String(localized: "cli.omo.noPackageManager", defaultValue: "Neither bun nor npm found in PATH. Install \(Self.omoPluginName) manually: bunx \(Self.omoPluginName) install")
    }

    private static func omoPluginInstalledMessage() -> String {
        String(localized: "cli.omo.pluginInstalled", defaultValue: "\(Self.omoPluginName) plugin installed")
    }

    private func omoWriteStatus(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    private func omoRequestedPort(from commandArgs: [String]) -> String? {
        for (index, arg) in commandArgs.enumerated() {
            if arg == "--port" {
                let nextIndex = commandArgs.index(after: index)
                guard nextIndex < commandArgs.endIndex else { return nil }
                let value = commandArgs[nextIndex].trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            }

            if arg.hasPrefix("--port=") {
                let value = String(arg.dropFirst("--port=".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            }
        }

        return nil
    }

    func omoBindableLoopbackPort(_ port: UInt16) -> UInt16? {
        let socketDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else { return nil }
        defer { close(socketDescriptor) }

        var reuseAddress: Int32 = 1
        _ = setsockopt(
            socketDescriptor,
            SOL_SOCKET,
            SO_REUSEADDR,
            &reuseAddress,
            socklen_t(MemoryLayout<Int32>.size)
        )

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.stride)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.stride))
            }
        }
        guard bindResult == 0 else { return nil }

        if port != 0 {
            return port
        }

        var boundAddress = address
        var boundAddressLength = socklen_t(MemoryLayout<sockaddr_in>.stride)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socketDescriptor, $0, &boundAddressLength)
            }
        }
        guard nameResult == 0 else { return nil }

        return UInt16(bigEndian: boundAddress.sin_port)
    }

    private func omoResolvedPort(
        commandArgs: [String],
        processEnvironment: [String: String]
    ) -> String {
        if let requestedPort = omoRequestedPort(from: commandArgs) {
            return requestedPort
        }

        if let environmentPort = processEnvironment["OPENCODE_PORT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           let parsedEnvironmentPort = UInt16(environmentPort),
           parsedEnvironmentPort != 0,
           omoBindableLoopbackPort(parsedEnvironmentPort) != nil {
            return environmentPort
        }

        if let preferredPort = omoBindableLoopbackPort(4096) {
            return String(preferredPort)
        }

        if let fallbackPort = omoBindableLoopbackPort(0) {
            return String(fallbackPort)
        }

        return "4096"
    }

    /// Creates a shadow config directory that layers oh-my-openagent on top of the user's
    /// existing opencode config without modifying the original. Sets OPENCODE_CONFIG_DIR
    /// to point at the shadow directory.
    private func omoEnsurePlugin(processEnvironment: [String: String]) throws {
        let userDir = omoUserConfigDir()
        let shadowDir = omoShadowConfigDir()
        let fm = FileManager.default

        try fm.createDirectory(at: shadowDir, withIntermediateDirectories: true, attributes: nil)

        // Read the user's opencode.json (if any), add the plugin, write to shadow dir
        let userJsonURL = userDir.appendingPathComponent("opencode.json")
        let shadowJsonURL = shadowDir.appendingPathComponent("opencode.json")

        var config: [String: Any]
        if let data = try? Data(contentsOf: userJsonURL) {
            guard let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CLIError(message: "Failed to parse \(userJsonURL.path). Fix the JSON syntax and retry.")
            }
            config = existing
        } else {
            config = [:]
        }

        var plugins = Self.openCodePluginListNormalizingOMOPlugin(
            Self.openCodePluginListRemovingSessionPlugin((config["plugin"] as? [Any]) ?? [])
        )
        if !Self.openCodePluginListContains(plugins, spec: Self.omoPluginName, allowVersionSuffix: true) {
            plugins.append(Self.omoPluginName)
        }
        config["plugin"] = plugins

        let output = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        try output.write(to: shadowJsonURL, options: .atomic)

        // Symlink node_modules from the user's config dir so installed packages resolve
        let shadowNodeModules = shadowDir.appendingPathComponent("node_modules")
        let userNodeModules = userDir.appendingPathComponent("node_modules")
        try omoEnsureShadowNodeModulesSymlink(shadowNodeModules: shadowNodeModules, userNodeModules: userNodeModules)

        // The shadow config owns its own package metadata so yanked/stale pins in the
        // user's opencode package.json/bun.lock cannot poison plugin installation.
        let shadowPackageURL = shadowDir.appendingPathComponent("package.json")
        let shadowBunLockURL = shadowDir.appendingPathComponent("bun.lock")
        try omoEnsureShadowPackageManifest(at: shadowPackageURL)
        if omoFileType(at: shadowBunLockURL) == .typeSymbolicLink {
            try? fm.removeItem(at: shadowBunLockURL)
        }

        try writeOpenCodeSessionPlugin(in: shadowDir)

        // Copy oh-my-openagent plugin config (jsonc) if the user has one.
        // Keep legacy filenames visible in the shadow dir so existing setups still load.
        for filename in [
            "oh-my-openagent.json",
            "oh-my-openagent.jsonc",
            "oh-my-opencode.json",
            "oh-my-opencode.jsonc"
        ] {
            let userFile = userDir.appendingPathComponent(filename)
            let shadowFile = shadowDir.appendingPathComponent(filename)
            if fm.fileExists(atPath: userFile.path) && !fm.fileExists(atPath: shadowFile.path) {
                try fm.createSymbolicLink(at: shadowFile, withDestinationURL: userFile)
            }
        }

        // Install the package if not available via the symlinked node_modules
        let pluginPackageDir = shadowNodeModules.appendingPathComponent(Self.omoPluginName)
        if !fm.fileExists(atPath: pluginPackageDir.path) {
            let installDir = shadowDir
            if let bunPath = resolveExecutableInPath("bun", searchPath: processEnvironment["PATH"]) {
                omoWriteStatus(Self.omoInstallingPluginMessage())
                let installArguments = ["add", Self.omoPluginName]
                let firstAttemptStatus = try omoRunPackageInstall(
                    executablePath: bunPath,
                    arguments: installArguments,
                    currentDirectoryURL: installDir,
                    environment: processEnvironment
                )
                if firstAttemptStatus != 0 {
                    omoWriteStatus(Self.omoRetryingInstallMessage())
                    try? fm.removeItem(at: shadowBunLockURL)
                    try? fm.removeItem(at: shadowNodeModules)
                    try omoEnsureShadowNodeModulesSymlink(shadowNodeModules: shadowNodeModules, userNodeModules: userNodeModules)
                    let retryStatus = try omoRunPackageInstall(
                        executablePath: bunPath,
                        arguments: installArguments,
                        currentDirectoryURL: installDir,
                        environment: processEnvironment
                    )
                    if retryStatus != 0 {
                        throw CLIError(message: Self.omoInstallFailedMessage())
                    }
                }
            } else if let npmPath = resolveExecutableInPath("npm", searchPath: processEnvironment["PATH"]) {
                omoWriteStatus(Self.omoInstallingPluginMessage())
                let status = try omoRunPackageInstall(
                    executablePath: npmPath,
                    arguments: ["install", Self.omoPluginName],
                    currentDirectoryURL: installDir,
                    environment: processEnvironment
                )
                if status != 0 {
                    throw CLIError(message: Self.omoInstallFailedMessage())
                }
            } else {
                throw CLIError(message: Self.omoNoPackageManagerMessage())
            }
            omoWriteStatus(Self.omoPluginInstalledMessage())
        }

        // Ensure tmux mode is enabled in oh-my-openagent config.
        // Without this, the TmuxSessionManager won't spawn visual panes even though
        // $TMUX is set (tmux.enabled defaults to false).
        let omoConfigURL = shadowDir.appendingPathComponent("oh-my-openagent.json")
        var omoConfig: [String: Any]
        if let data = try? Data(contentsOf: omoConfigURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            omoConfig = existing
        } else {
            // Check if user has a current or legacy config and write the normalized
            // shadow copy under the current package name.
            let userOmoConfigURLs = [
                userDir.appendingPathComponent("oh-my-openagent.json"),
                userDir.appendingPathComponent("oh-my-opencode.json"),
                shadowDir.appendingPathComponent("oh-my-opencode.json")
            ]
            if let existing = userOmoConfigURLs.lazy.compactMap({ url -> [String: Any]? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
                return object as? [String: Any]
            }).first {
                omoConfig = existing
                // Remove the symlink so we can write our own copy
                try? fm.removeItem(at: omoConfigURL)
            } else {
                omoConfig = [:]
            }
        }
        var tmuxConfig = (omoConfig["tmux"] as? [String: Any]) ?? [:]
        var needsWrite = false
        if tmuxConfig["enabled"] as? Bool != true {
            tmuxConfig["enabled"] = true
            needsWrite = true
        }
        // Lower the default min widths so agent panes spawn in normal-sized windows.
        // oh-my-openagent defaults: main_pane_min_width=120, agent_pane_min_width=40,
        // requiring 161+ columns. Most terminal windows are narrower.
        if tmuxConfig["main_pane_min_width"] == nil {
            tmuxConfig["main_pane_min_width"] = 60
            needsWrite = true
        }
        if tmuxConfig["agent_pane_min_width"] == nil {
            tmuxConfig["agent_pane_min_width"] = 30
            needsWrite = true
        }
        if tmuxConfig["main_pane_size"] == nil {
            tmuxConfig["main_pane_size"] = 50
            needsWrite = true
        }
        if needsWrite {
            omoConfig["tmux"] = tmuxConfig
            // Remove symlink if it exists (we need a real file)
            if let attrs = try? fm.attributesOfItem(atPath: omoConfigURL.path),
               attrs[.type] as? FileAttributeType == .typeSymbolicLink {
                try? fm.removeItem(at: omoConfigURL)
            }
            let output = try JSONSerialization.data(withJSONObject: omoConfig, options: [.prettyPrinted, .sortedKeys])
            try output.write(to: omoConfigURL, options: .atomic)
        }

        // Point OpenCode at the shadow config
        setenv("OPENCODE_CONFIG_DIR", shadowDir.path, 1)
    }

    private func configureOMOEnvironment(
        processEnvironment: [String: String],
        shimDirectory: URL,
        executablePath: String,
        socketPath: String,
        explicitPassword: String?,
        focusedContext: TmuxCompatFocusedContext?,
        openCodePort: String
    ) {
        configureTmuxCompatEnvironment(
            processEnvironment: processEnvironment,
            shimDirectory: shimDirectory,
            executablePath: executablePath,
            socketPath: socketPath,
            explicitPassword: explicitPassword,
            focusedContext: focusedContext,
            tmuxPathPrefix: "cmux-omo",
            cmuxBinEnvVar: "CMUX_OMO_CMUX_BIN",
            termOverrideEnvVar: "CMUX_OMO_TERM",
            extraEnvVars: [
                (key: "OPENCODE_PORT", value: openCodePort),
                (key: "CMUX_OPENCODE_CMUX_BIN", value: executablePath),
            ]
        )
    }

    func runOMO(
        commandArgs: [String],
        socketPath: String,
        explicitPassword: String?
    ) throws {
        let processEnvironment = ProcessInfo.processInfo.environment
        var launcherEnvironment = processEnvironment
        launcherEnvironment["CMUX_SOCKET_PATH"] = socketPath; launcherEnvironment.removeValue(forKey: "CMUX_SOCKET")
        if let explicitPassword,
           !explicitPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            launcherEnvironment["CMUX_SOCKET_PASSWORD"] = explicitPassword
        }

        guard let openCodeExecutablePath = resolveOpenCodeExecutable(searchPath: launcherEnvironment["PATH"]) else {
            throw CLIError(message: missingProviderExecutableMessage(
                displayName: "OpenCode",
                executableName: "opencode"
            ))
        }
        launcherEnvironment["PATH"] = providerExecutableSearchPath(
            searchPath: launcherEnvironment["PATH"],
            includingExecutableAt: openCodeExecutablePath
        )

        // Ensure oh-my-openagent plugin is registered and installed
        try omoEnsurePlugin(processEnvironment: launcherEnvironment)

        let shimDirectory = try createOMOShimDirectory()
        let executablePath = resolvedExecutableURL()?.path ?? (args.first ?? "cmux")
        let focusedContext = try tmuxCompatFocusedContext(
            processEnvironment: launcherEnvironment,
            explicitPassword: explicitPassword
        )
        let openCodePort = omoResolvedPort(
            commandArgs: commandArgs,
            processEnvironment: launcherEnvironment
        )
        launcherEnvironment["OPENCODE_PORT"] = openCodePort
        configureOMOEnvironment(
            processEnvironment: launcherEnvironment,
            shimDirectory: shimDirectory,
            executablePath: executablePath,
            socketPath: socketPath,
            explicitPassword: explicitPassword,
            focusedContext: focusedContext,
            openCodePort: openCodePort
        )

        let launchPath = openCodeExecutablePath
        // oh-my-openagent needs the OpenCode API server running to attach
        // subagent sessions to tmux panes. Prefer the historic default port
        // when it is available, otherwise fall back to a free loopback port.
        var effectiveArgs = commandArgs
        if omoRequestedPort(from: commandArgs) == nil {
            effectiveArgs.append("--port")
            effectiveArgs.append(openCodePort)
        }
        exportAgentLaunchCommandEnvironment(
            launcher: "omo",
            executablePath: executablePath,
            arguments: [executablePath, "omo"] + effectiveArgs,
            workingDirectory: launcherEnvironment["PWD"]
        )
        var argv = ([launchPath] + effectiveArgs).map { strdup($0) }
        defer {
            for item in argv {
                free(item)
            }
        }
        argv.append(nil)

        execv(launchPath, &argv)
        let code = errno
        throw CLIError(message: "Failed to launch opencode: \(String(cString: strerror(code)))\n\nIs opencode installed? Install with:\n  npm install -g opencode-ai")
    }

    // MARK: - cmux omx (Oh My Codex)

}
