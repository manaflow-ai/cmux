import CmuxCore
import CmuxFoundation
import Darwin
import Foundation

enum VSCodeServeWebURLBuilder {
    static func extractWebUIURL(from output: String) -> URL? {
        let prefix = "Web UI available at "
        for line in output.split(whereSeparator: \.isNewline).reversed() {
            guard let range = line.range(of: prefix) else { continue }
            let rawURL = line[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawURL.isEmpty, let url = URL(string: rawURL) else { continue }
            return url
        }
        return nil
    }

    static func openFolderURL(baseWebUIURL: URL, directoryPath: String) -> URL? {
        var components = URLComponents(url: baseWebUIURL, resolvingAgainstBaseURL: false)
        var queryItems = components?.queryItems ?? []
        queryItems.removeAll { $0.name == "folder" }
        queryItems.append(URLQueryItem(name: "folder", value: directoryPath))
        components?.queryItems = queryItems
        return components?.url
    }
}

/// Which binary backs the inline serve-web launch. The two differ in how VS Code
/// Web persists auth/Settings Sync state, so downstream launch options are shaped
/// per kind (see ``VSCodeServeWebLaunchOptionsBuilder``).
enum VSCodeServeWebLauncherKind: Equatable {
    /// `code-tunnel serve-web`: the wrapper that wires up the CLI
    /// secret-storage/keyring path VS Code Web auth + Settings Sync rely on.
    case codeTunnelWrapper
    /// Cached `~/.vscode/cli/serve-web/<id>/bin/code-server`, used only as a
    /// fallback for installs where the wrapper is unavailable. Bypasses the
    /// wrapper-managed keyring setup.
    case cachedCodeServer
}

struct VSCodeCLILaunchConfiguration {
    let executableURL: URL
    let argumentsPrefix: [String]
    let environment: [String: String]
    let launcherKind: VSCodeServeWebLauncherKind
}

enum VSCodeCLILaunchConfigurationBuilder {
    private struct VSCodeProductMetadata: Decodable {
        let dataFolderName: String?
    }

    static func launchConfiguration(
        vscodeApplicationURL: URL,
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        isExecutableAtPath: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        dataAtURL: (URL) -> Data? = { try? Data(contentsOf: $0) },
        contentsOfDirectoryAtURL: (URL) -> [URL] = { url in
            (try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []
        },
        contentModificationDateAtURL: (URL) -> Date? = { url in
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }
    ) -> VSCodeCLILaunchConfiguration? {
        let contentsURL = vscodeApplicationURL.appendingPathComponent("Contents", isDirectory: true)
        let environment = nodeSafeEnvironment(from: baseEnvironment)

        // Prefer the `code-tunnel serve-web` wrapper. It owns the CLI
        // secret-storage/keyring setup that VS Code Web uses to persist GitHub
        // auth + Settings Sync across reloads/folder changes/app relaunches.
        // Launching the cached `code-server` binary directly bypasses that path
        // and loses the auth/settings state (issue #6595).
        let codeTunnelURL = contentsURL.appendingPathComponent("Resources/app/bin/code-tunnel", isDirectory: false)
        if isExecutableAtPath(codeTunnelURL.path) {
            var codeTunnelEnvironment = environment
            codeTunnelEnvironment["ELECTRON_RUN_AS_NODE"] = "1"
            return VSCodeCLILaunchConfiguration(
                executableURL: codeTunnelURL,
                argumentsPrefix: ["serve-web"],
                environment: codeTunnelEnvironment,
                launcherKind: .codeTunnelWrapper
            )
        }

        // Fallback: the cached code-server binary for installs without the wrapper.
        if let codeServerURL = preferredCachedCodeServerURL(
            contentsURL: contentsURL,
            homeDirectoryURL: homeDirectoryURL,
            isExecutableAtPath: isExecutableAtPath,
            dataAtURL: dataAtURL,
            contentsOfDirectoryAtURL: contentsOfDirectoryAtURL,
            contentModificationDateAtURL: contentModificationDateAtURL
        ) {
            var codeServerEnvironment = environment
            codeServerEnvironment.removeValue(forKey: "ELECTRON_RUN_AS_NODE")
            return VSCodeCLILaunchConfiguration(
                executableURL: codeServerURL,
                argumentsPrefix: [],
                environment: codeServerEnvironment,
                launcherKind: .cachedCodeServer
            )
        }

        return nil
    }

    private static func nodeSafeEnvironment(from baseEnvironment: [String: String]) -> [String: String] {
        var environment = baseEnvironment
        environment.removeValue(forKey: "VSCODE_NODE_OPTIONS")
        environment.removeValue(forKey: "VSCODE_NODE_REPL_EXTERNAL_MODULE")
        if let nodeOptions = environment["NODE_OPTIONS"] {
            environment["VSCODE_NODE_OPTIONS"] = nodeOptions
        }
        if let nodeReplExternalModule = environment["NODE_REPL_EXTERNAL_MODULE"] {
            environment["VSCODE_NODE_REPL_EXTERNAL_MODULE"] = nodeReplExternalModule
        }
        environment.removeValue(forKey: "NODE_OPTIONS")
        environment.removeValue(forKey: "NODE_REPL_EXTERNAL_MODULE")
        return environment
    }

    private static func preferredCachedCodeServerURL(
        contentsURL: URL,
        homeDirectoryURL: URL,
        isExecutableAtPath: (String) -> Bool,
        dataAtURL: (URL) -> Data?,
        contentsOfDirectoryAtURL: (URL) -> [URL],
        contentModificationDateAtURL: (URL) -> Date?
    ) -> URL? {
        let dataFolderName = vscodeDataFolderName(
            contentsURL: contentsURL,
            dataAtURL: dataAtURL
        )
        let serveWebCacheURL = homeDirectoryURL
            .appendingPathComponent(dataFolderName, isDirectory: true)
            .appendingPathComponent("cli/serve-web", isDirectory: true)

        if let orderedCacheIDs = serveWebLRUCacheIDs(
            serveWebCacheURL: serveWebCacheURL,
            dataAtURL: dataAtURL
        ) {
            for cacheID in orderedCacheIDs {
                let codeServerURL = serveWebCacheURL
                    .appendingPathComponent(cacheID, isDirectory: true)
                    .appendingPathComponent("bin/code-server", isDirectory: false)
                if isExecutableAtPath(codeServerURL.path) {
                    return codeServerURL
                }
            }
        }

        let candidates = contentsOfDirectoryAtURL(serveWebCacheURL)
            .map {
                $0.appendingPathComponent("bin/code-server", isDirectory: false)
            }
            .filter {
                isExecutableAtPath($0.path)
            }
            .sorted { lhs, rhs in
                let lhsDate = contentModificationDateAtURL(lhs) ?? .distantPast
                let rhsDate = contentModificationDateAtURL(rhs) ?? .distantPast
                if lhsDate != rhsDate {
                    return lhsDate > rhsDate
                }
                return lhs.path > rhs.path
            }

        return candidates.first
    }

    private static func vscodeDataFolderName(
        contentsURL: URL,
        dataAtURL: (URL) -> Data?
    ) -> String {
        let productURL = contentsURL.appendingPathComponent("Resources/app/product.json", isDirectory: false)
        guard let data = dataAtURL(productURL),
              let product = try? JSONDecoder().decode(VSCodeProductMetadata.self, from: data),
              let dataFolderName = product.dataFolderName,
              isSafePathComponent(dataFolderName) else {
            return ".vscode"
        }
        return dataFolderName
    }

    private static func serveWebLRUCacheIDs(
        serveWebCacheURL: URL,
        dataAtURL: (URL) -> Data?
    ) -> [String]? {
        let lruURL = serveWebCacheURL.appendingPathComponent("lru.json", isDirectory: false)
        guard let data = dataAtURL(lruURL),
              let cacheIDs = try? JSONDecoder().decode([String].self, from: data) else {
            return nil
        }
        return cacheIDs.filter(isSafePathComponent)
    }

    private static func isSafePathComponent(_ component: String) -> Bool {
        guard !component.isEmpty, component != ".", component != ".." else { return false }
        return component.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\")) == nil
    }
}

/// Stable on-disk locations + port for the inline serve-web server. Keeping these
/// fixed across launches is what lets VS Code Web's keyring/secret-storage survive
/// reloads, folder changes, and app relaunches (issue #6595).
struct VSCodeServeWebRuntimeLocation: Equatable {
    /// `--server-data-dir`: where serve-web keeps its server-side state.
    let serverDataDirectoryURL: URL
    /// `--user-data-dir` for the cached code-server fallback (the wrapper derives
    /// this from `--server-data-dir` and rejects the flag).
    let userDataDirectoryURL: URL
    /// `VSCODE_CLI_DATA_DIR` for the wrapper's CLI keyring metadata.
    let cliDataDirectoryURL: URL
    /// `--connection-token-file`: a persisted token so the server URL is stable.
    let connectionTokenFileURL: URL
    /// Stable serve-web port (or `0` for the ephemeral fallback attempt).
    let port: Int
}

enum VSCodeServeWebRuntimeLocator {
    /// Override the serve-web server data directory (absolute path).
    static let serverDataDirectoryEnvironmentKey = "CMUX_VSCODE_SERVE_WEB_DATA_DIR"
    /// Override the stable serve-web port.
    static let portEnvironmentKey = "CMUX_VSCODE_SERVE_WEB_PORT"
    /// VS Code CLI data dir env var; honored as-is when already set.
    static let cliDataDirectoryEnvironmentKey = "VSCODE_CLI_DATA_DIR"
    /// UserDefaults key the resolved default port is persisted under.
    static let portUserDefaultsKey = "vscodeServeWeb.port"

    /// IANA dynamic/private port range (49152–65535) avoids well-known and
    /// registered ports while still giving every bundle a stable default.
    private static let minimumPort = 49152
    private static let portRangeSize = 16384

    static func resolve(
        applicationSupportURL: URL,
        bundleIdentifier: String,
        environment: [String: String],
        persistedPort: Int?
    ) -> (location: VSCodeServeWebRuntimeLocation, portToPersist: Int?) {
        let serverDataDirectoryURL = resolveServerDataDirectoryURL(
            applicationSupportURL: applicationSupportURL,
            bundleIdentifier: bundleIdentifier,
            environment: environment
        )
        let userDataDirectoryURL = serverDataDirectoryURL
            .appendingPathComponent("user-data", isDirectory: true)
        let cliDataDirectoryURL = resolveCLIDataDirectoryURL(
            serverDataDirectoryURL: serverDataDirectoryURL,
            environment: environment
        )
        let connectionTokenFileURL = serverDataDirectoryURL
            .appendingPathComponent("connection-token", isDirectory: false)
        let (port, portToPersist) = resolvePort(
            bundleIdentifier: bundleIdentifier,
            environment: environment,
            persistedPort: persistedPort
        )

        return (
            VSCodeServeWebRuntimeLocation(
                serverDataDirectoryURL: serverDataDirectoryURL,
                userDataDirectoryURL: userDataDirectoryURL,
                cliDataDirectoryURL: cliDataDirectoryURL,
                connectionTokenFileURL: connectionTokenFileURL,
                port: port
            ),
            portToPersist
        )
    }

    private static func resolveServerDataDirectoryURL(
        applicationSupportURL: URL,
        bundleIdentifier: String,
        environment: [String: String]
    ) -> URL {
        if let override = environment[serverDataDirectoryEnvironmentKey],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return applicationSupportURL
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("vscode-serve-web", isDirectory: true)
    }

    private static func resolveCLIDataDirectoryURL(
        serverDataDirectoryURL: URL,
        environment: [String: String]
    ) -> URL {
        if let override = environment[cliDataDirectoryEnvironmentKey],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return serverDataDirectoryURL.appendingPathComponent("cli-data", isDirectory: true)
    }

    private static func resolvePort(
        bundleIdentifier: String,
        environment: [String: String],
        persistedPort: Int?
    ) -> (port: Int, portToPersist: Int?) {
        if let override = environment[portEnvironmentKey], let parsed = parsePort(override) {
            // Env overrides win but are intentionally not persisted as the default.
            return (parsed, nil)
        }
        if let persistedPort, isValidPort(persistedPort) {
            return (persistedPort, nil)
        }
        let derived = derivePort(from: bundleIdentifier)
        return (derived, derived)
    }

    static func parsePort(_ raw: String) -> Int? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed), isValidPort(value) else { return nil }
        return value
    }

    static func isValidPort(_ port: Int) -> Bool {
        (1024...65535).contains(port)
    }

    /// Deterministic per-bundle default so different (e.g. tagged) builds get
    /// distinct, stable ports instead of colliding on one fixed value.
    static func derivePort(from bundleIdentifier: String) -> Int {
        var hash: UInt64 = 1469598103934665603 // FNV-1a 64-bit offset basis
        for byte in bundleIdentifier.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211 // FNV-1a 64-bit prime
        }
        return minimumPort + Int(hash % UInt64(portRangeSize))
    }
}

/// Connection-token format helpers. VS Code Web compares the URL `tkn` query item
/// against this file's contents, so a stable, valid token keeps the server URL —
/// and the browser-side session/cookies keyed to it — consistent across launches.
enum VSCodeConnectionToken {
    private static let hexCharacters = Set("0123456789abcdefABCDEF")

    static func isValid(_ token: String) -> Bool {
        guard token.count == 32 else { return false }
        return token.allSatisfy { hexCharacters.contains($0) }
    }

    /// 128 bits of randomness rendered as 32 lowercase hex characters.
    static func generate() -> String {
        let hexDigits = Array("0123456789abcdef")
        var characters = [Character]()
        characters.reserveCapacity(32)
        for _ in 0..<16 {
            let byte = UInt8.random(in: UInt8.min...UInt8.max)
            characters.append(hexDigits[Int(byte >> 4)])
            characters.append(hexDigits[Int(byte & 0x0F)])
        }
        return String(characters)
    }
}

/// Reads/creates the persisted connection-token file, reusing a valid existing
/// token (32-hex, owner-only perms) and replacing anything invalid.
enum VSCodeConnectionTokenStore {
    @discardableResult
    static func ensureToken(at url: URL, fileManager: FileManager = .default) -> String? {
        if let existing = readValidToken(at: url, fileManager: fileManager) {
            return existing
        }
        return writeToken(VSCodeConnectionToken.generate(), to: url, fileManager: fileManager)
    }

    static func readValidToken(at url: URL, fileManager: FileManager) -> String? {
        guard let data = try? Data(contentsOf: url),
              let raw = String(data: data, encoding: .utf8) else {
            return nil
        }
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard VSCodeConnectionToken.isValid(token),
              hasOwnerOnlyPermissions(at: url, fileManager: fileManager) else {
            return nil
        }
        return token
    }

    static func hasOwnerOnlyPermissions(at url: URL, fileManager: FileManager) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let permissions = attributes[.posixPermissions] as? NSNumber else {
            return false
        }
        // No group/other bits set (e.g. 0600/0400).
        return permissions.uint16Value & 0o077 == 0
    }

    @discardableResult
    static func writeToken(_ token: String, to url: URL, fileManager: FileManager) -> String? {
        guard let tokenData = token.data(using: .utf8) else { return nil }
        try? fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Drop any stale/invalid file so the strict-perms create below succeeds.
        try? fileManager.removeItem(at: url)

        let fileDescriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard fileDescriptor >= 0 else { return nil }
        defer { _ = close(fileDescriptor) }

        let wroteAllBytes = tokenData.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return false }
            return write(fileDescriptor, baseAddress, rawBuffer.count) == rawBuffer.count
        }
        guard wroteAllBytes else {
            try? fileManager.removeItem(at: url)
            return nil
        }
        // Pin to 0600 in case umask widened the create mode.
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return token
    }
}

struct VSCodeServeWebLaunchOptions: Equatable {
    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]
}

/// Shapes the final process arguments + environment per launcher kind. The wrapper
/// and the cached code-server differ in supported flags and in how they manage the
/// secret keyring, so the two paths are handled explicitly here.
enum VSCodeServeWebLaunchOptionsBuilder {
    static func launchOptions(
        configuration: VSCodeCLILaunchConfiguration,
        location: VSCodeServeWebRuntimeLocation,
        port: Int
    ) -> VSCodeServeWebLaunchOptions {
        var arguments = configuration.argumentsPrefix
        arguments += [
            "--accept-server-license-terms",
            "--host", "127.0.0.1",
            "--port", String(port),
            "--connection-token-file", location.connectionTokenFileURL.path,
            "--server-data-dir", location.serverDataDirectoryURL.path,
        ]
        var environment = configuration.environment

        switch configuration.launcherKind {
        case .codeTunnelWrapper:
            // `code-tunnel serve-web` does not accept --user-data-dir; it derives
            // user data from --server-data-dir. Enable the CLI file keyring so VS
            // Code Web auth/Settings Sync persist instead of using in-memory
            // secret storage, and pin the CLI data dir for keyring stability.
            environment["VSCODE_CLI_USE_FILE_KEYRING"] = "1"
            let cliDataKey = VSCodeServeWebRuntimeLocator.cliDataDirectoryEnvironmentKey
            let cliDataDirIsUnset = environment[cliDataKey]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty ?? true
            if cliDataDirIsUnset {
                environment[cliDataKey] = location.cliDataDirectoryURL.path
            }
        case .cachedCodeServer:
            // The cached server binary accepts --user-data-dir directly.
            arguments += ["--user-data-dir", location.userDataDirectoryURL.path]
        }

        return VSCodeServeWebLaunchOptions(
            executableURL: configuration.executableURL,
            arguments: arguments,
            environment: environment
        )
    }
}

final class VSCodeServeWebController {
    static let shared = VSCodeServeWebController()
    private static let serveWebStartupTimeoutSeconds: TimeInterval = 60
    /// Used to namespace the serve-web data dir when the running app has no bundle
    /// identifier (e.g. some test hosts). Matches the release bundle id.
    private static let fallbackBundleIdentifier = "com.cmuxterm.app"

    private let queue = DispatchQueue(label: "cmux.vscode.serveWeb")
    private let launchQueue = DispatchQueue(label: "cmux.vscode.serveWeb.launch")
    private let launchProcessOverride: ((URL, UInt64) -> (process: Process, url: URL)?)?
    private var serveWebProcess: Process?
    private var launchingProcess: Process?
    private var serveWebURL: URL?
    private var pendingCompletions: [(generation: UInt64, completion: (URL?) -> Void)] = []
    private var isLaunching = false
    private var activeLaunchGeneration: UInt64?
    private var lifecycleGeneration: UInt64 = 0

    // Internal (not private) so tests can inject `launchProcessOverride` via
    // `@testable import` instead of a `#if DEBUG` production test seam.
    init(launchProcessOverride: ((URL, UInt64) -> (process: Process, url: URL)?)? = nil) {
        self.launchProcessOverride = launchProcessOverride
    }

    func ensureServeWebURL(vscodeApplicationURL: URL, completion: @escaping (URL?) -> Void) {
        queue.async {
            if let process = self.serveWebProcess,
               process.isRunning,
               let url = self.serveWebURL {
                DispatchQueue.main.async {
                    completion(url)
                }
                return
            }

            let completionGeneration = self.lifecycleGeneration
            self.pendingCompletions.append((generation: completionGeneration, completion: completion))
            guard !self.isLaunching else { return }

            self.isLaunching = true
            let launchGeneration = completionGeneration
            self.activeLaunchGeneration = launchGeneration

            self.launchQueue.async {
                let shouldLaunch = self.queue.sync {
                    self.lifecycleGeneration == launchGeneration
                }
                guard shouldLaunch else {
                    self.queue.async {
                        guard self.activeLaunchGeneration == launchGeneration else { return }
                        self.isLaunching = false
                        self.activeLaunchGeneration = nil
                    }
                    return
                }
                let launchResult = self.launchServeWebProcess(
                    vscodeApplicationURL: vscodeApplicationURL,
                    expectedGeneration: launchGeneration
                )
                self.queue.async {
                    guard self.activeLaunchGeneration == launchGeneration else {
                        if let process = launchResult?.process, process.isRunning {
                            process.terminate()
                        }
                        return
                    }
                    self.isLaunching = false
                    self.activeLaunchGeneration = nil

                    guard self.lifecycleGeneration == launchGeneration else {
                        if let launchedProcess = launchResult?.process,
                           self.launchingProcess === launchedProcess {
                            self.launchingProcess = nil
                        }
                        if let process = launchResult?.process, process.isRunning {
                            process.terminate()
                        }
                        return
                    }

                    if let launchResult {
                        self.launchingProcess = nil
                        self.serveWebProcess = launchResult.process
                        self.serveWebURL = launchResult.url
                    } else {
                        self.launchingProcess = nil
                        self.serveWebProcess = nil
                        self.serveWebURL = nil
                    }

                    var completions: [(URL?) -> Void] = []
                    var remaining: [(generation: UInt64, completion: (URL?) -> Void)] = []
                    for pending in self.pendingCompletions {
                        if pending.generation == launchGeneration {
                            completions.append(pending.completion)
                        } else {
                            remaining.append(pending)
                        }
                    }
                    self.pendingCompletions = remaining
                    let resolvedURL = self.serveWebURL
                    DispatchQueue.main.async {
                        completions.forEach { $0(resolvedURL) }
                    }
                }
            }
        }
    }

    func stop() {
        // The connection-token file is now persisted under the stable server data
        // dir and reused across launches, so stop() must NOT delete it — doing so
        // would change the server URL and drop VS Code Web auth/Settings Sync.
        let (processes, completions): ([Process], [(URL?) -> Void]) = queue.sync {
            self.lifecycleGeneration &+= 1
            self.isLaunching = false
            self.activeLaunchGeneration = nil
            var processes: [Process] = []
            if let process = self.serveWebProcess {
                processes.append(process)
            }
            if let process = self.launchingProcess,
               !processes.contains(where: { $0 === process }) {
                processes.append(process)
            }
            self.serveWebProcess = nil
            self.launchingProcess = nil
            self.serveWebURL = nil
            let completions = self.pendingCompletions.map(\.completion)
            self.pendingCompletions.removeAll()
            return (processes, completions)
        }

        for process in processes where process.isRunning {
            process.terminate()
        }

        if !completions.isEmpty {
            DispatchQueue.main.async {
                completions.forEach { $0(nil) }
            }
        }
    }

    func restart(vscodeApplicationURL: URL, completion: @escaping (URL?) -> Void) {
        stop()
        ensureServeWebURL(vscodeApplicationURL: vscodeApplicationURL, completion: completion)
    }

    func isServeWebURL(_ candidateURL: URL?) -> Bool {
        guard let candidateURL else { return false }
        let serveWebURL = queue.sync {
            self.serveWebURL
        }
        return Self.urlsShareLoopbackOrigin(candidateURL, serveWebURL)
    }

    private func launchServeWebProcess(
        vscodeApplicationURL: URL,
        expectedGeneration: UInt64
    ) -> (process: Process, url: URL)? {
        if let launchProcessOverride {
            return launchProcessOverride(vscodeApplicationURL, expectedGeneration)
        }

        guard let launchConfiguration = VSCodeCLILaunchConfigurationBuilder.launchConfiguration(
            vscodeApplicationURL: vscodeApplicationURL
        ) else { return nil }

        guard let location = prepareRuntimeLocation() else { return nil }

        // Persist a stable, valid connection token so the server URL (and the
        // browser-side session keyed to its token) stays consistent across launches.
        guard VSCodeConnectionTokenStore.ensureToken(at: location.connectionTokenFileURL) != nil else {
            return nil
        }

        // Try the stable port first; fall back to an ephemeral port if it can't be
        // bound (e.g. already in use) so the inline server still comes up.
        var attemptedPorts = [location.port]
        if location.port != 0 {
            attemptedPorts.append(0)
        }

        for port in attemptedPorts {
            let options = VSCodeServeWebLaunchOptionsBuilder.launchOptions(
                configuration: launchConfiguration,
                location: location,
                port: port
            )
            if let result = runServeWebProcess(options: options, expectedGeneration: expectedGeneration) {
                return result
            }
            // Stop retrying if this launch generation was superseded mid-attempt.
            let stillCurrent = queue.sync {
                self.lifecycleGeneration == expectedGeneration
                    && self.activeLaunchGeneration == expectedGeneration
            }
            guard stillCurrent else { return nil }
        }

        return nil
    }

    /// Runs a single serve-web launch attempt for the given options, returning the
    /// process + resolved Web UI URL on success. The persisted connection-token
    /// file is intentionally never deleted here — it must survive process exits.
    private func runServeWebProcess(
        options: VSCodeServeWebLaunchOptions,
        expectedGeneration: UInt64
    ) -> (process: Process, url: URL)? {
        let process = Process()
        process.executableURL = options.executableURL
        process.arguments = options.arguments
        process.environment = options.environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let collector = ServeWebOutputCollector()
        let outputReader: (FileHandle) -> Void = { fileHandle in
            switch fileHandle.readAvailableDataOrEndOfFile() {
            case .data(let data):
                collector.append(data)
            case .wouldBlock:
                return
            case .endOfFile:
                fileHandle.readabilityHandler = nil
            }
        }
        stdoutPipe.fileHandleForReading.readabilityHandler = outputReader
        stderrPipe.fileHandleForReading.readabilityHandler = outputReader

        process.terminationHandler = { [weak self] terminatedProcess in
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            Self.drainAvailableOutput(from: stdoutPipe.fileHandleForReading, collector: collector)
            Self.drainAvailableOutput(from: stderrPipe.fileHandleForReading, collector: collector)
            collector.markProcessExited()
            self?.queue.async {
                guard let self else { return }
                if self.launchingProcess === terminatedProcess {
                    self.launchingProcess = nil
                }
                if self.serveWebProcess === terminatedProcess {
                    self.serveWebProcess = nil
                    self.serveWebURL = nil
                }
            }
        }

        let didStart: Bool = queue.sync {
            guard self.lifecycleGeneration == expectedGeneration,
                  self.activeLaunchGeneration == expectedGeneration else {
                return false
            }
            self.launchingProcess = process
            do {
                try process.run()
                return true
            } catch {
                if self.launchingProcess === process {
                    self.launchingProcess = nil
                }
                return false
            }
        }
        guard didStart else {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            return nil
        }

        guard collector.waitForURL(timeoutSeconds: Self.serveWebStartupTimeoutSeconds),
              let serveWebURL = collector.webUIURL else {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            if process.isRunning {
                process.terminate()
            } else {
                queue.sync {
                    if self.launchingProcess === process {
                        self.launchingProcess = nil
                    }
                    if self.serveWebProcess === process {
                        self.serveWebProcess = nil
                        self.serveWebURL = nil
                    }
                }
            }
            return nil
        }

        return (process, serveWebURL)
    }

    /// Resolves the stable serve-web paths + port, persisting the derived default
    /// port and ensuring the data directories exist before launch.
    private func prepareRuntimeLocation() -> VSCodeServeWebRuntimeLocation? {
        guard let applicationSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? Self.fallbackBundleIdentifier
        let resolved = VSCodeServeWebRuntimeLocator.resolve(
            applicationSupportURL: applicationSupportURL,
            bundleIdentifier: bundleIdentifier,
            environment: ProcessInfo.processInfo.environment,
            persistedPort: Self.persistedPort()
        )
        if let portToPersist = resolved.portToPersist {
            Self.persistPort(portToPersist)
        }

        let location = resolved.location
        let fileManager = FileManager.default
        // These directories hold long-lived VS Code Web auth, Settings Sync, and
        // CLI keyring state, so keep them owner-only (0700) to match the 0600
        // connection-token file. serverDataDirectoryURL is created first since it
        // is the parent of the user-data/cli-data subdirectories.
        let ownerOnly: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        for directoryURL in [
            location.serverDataDirectoryURL,
            location.userDataDirectoryURL,
            location.cliDataDirectoryURL,
        ] {
            try? fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: ownerOnly
            )
            // Pin to 0700 even if the directory pre-existed with looser perms (e.g.
            // created by an older build or a wider umask).
            try? fileManager.setAttributes(ownerOnly, ofItemAtPath: directoryURL.path)
        }
        return location
    }

    private static func persistedPort() -> Int? {
        let value = UserDefaults.standard.integer(forKey: VSCodeServeWebRuntimeLocator.portUserDefaultsKey)
        return value > 0 ? value : nil
    }

    private static func persistPort(_ port: Int) {
        UserDefaults.standard.set(port, forKey: VSCodeServeWebRuntimeLocator.portUserDefaultsKey)
    }

    private static func drainAvailableOutput(from fileHandle: FileHandle, collector: ServeWebOutputCollector) {
        while true {
            switch fileHandle.readAvailableDataOrEndOfFile() {
            case .data(let data):
                collector.append(data)
            case .wouldBlock, .endOfFile:
                return
            }
        }
    }

    private static func urlsShareLoopbackOrigin(_ lhs: URL, _ rhs: URL?) -> Bool {
        guard let rhs else { return false }
        guard lhs.scheme?.lowercased() == "http",
              rhs.scheme?.lowercased() == "http" else {
            return false
        }
        guard lhs.port == rhs.port, lhs.port != nil else { return false }
        guard let lhsHost = BrowserInsecureHTTPSettings.normalizeHost(lhs.host ?? ""),
              let rhsHost = BrowserInsecureHTTPSettings.normalizeHost(rhs.host ?? "") else {
            return false
        }
        return RemoteLoopbackProxyAlias.isLoopbackHost(lhsHost)
            && RemoteLoopbackProxyAlias.isLoopbackHost(rhsHost)
    }
}

final class ServeWebOutputCollector {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var outputBuffer = ""
    private var resolvedURL: URL?
    private var didSignal = false

    var webUIURL: URL? {
        lock.lock()
        defer { lock.unlock() }
        return resolvedURL
    }

    func append(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard resolvedURL == nil else { return }
        outputBuffer.append(text)
        while let newlineIndex = outputBuffer.firstIndex(where: \.isNewline) {
            let line = String(outputBuffer[..<newlineIndex])
            outputBuffer.removeSubrange(...newlineIndex)
            guard let parsedURL = VSCodeServeWebURLBuilder.extractWebUIURL(from: line) else {
                continue
            }
            resolvedURL = parsedURL
            outputBuffer.removeAll(keepingCapacity: false)
            if !didSignal {
                didSignal = true
                semaphore.signal()
            }
            return
        }
    }

    func markProcessExited() {
        lock.lock()
        defer { lock.unlock() }
        if resolvedURL == nil, !outputBuffer.isEmpty,
           let parsedURL = VSCodeServeWebURLBuilder.extractWebUIURL(from: outputBuffer) {
            resolvedURL = parsedURL
            outputBuffer.removeAll(keepingCapacity: false)
        }
        guard !didSignal else { return }
        didSignal = true
        semaphore.signal()
    }

    func waitForURL(timeoutSeconds: TimeInterval) -> Bool {
        if webUIURL != nil { return true }
        _ = semaphore.wait(timeout: .now() + timeoutSeconds)
        return webUIURL != nil
    }
}
