import AppKit
import Darwin
import Foundation

enum FinderServicePathResolver {
    private static func canonicalDirectoryPath(_ path: String) -> String {
        guard path.count > 1 else { return path }
        var canonical = path
        while canonical.count > 1 && canonical.hasSuffix("/") {
            canonical.removeLast()
        }
        return canonical
    }

    private static func normalizedComparisonURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func isSameOrDescendant(_ url: URL, of rootURL: URL) -> Bool {
        let urlPathComponents = normalizedComparisonURL(url).pathComponents
        let rootPathComponents = normalizedComparisonURL(rootURL).pathComponents
        guard urlPathComponents.count >= rootPathComponents.count else { return false }
        return Array(urlPathComponents.prefix(rootPathComponents.count)) == rootPathComponents
    }

    private static func resolvedDirectoryURL(from url: URL) -> URL {
        let standardized = url.standardizedFileURL
        if standardized.hasDirectoryPath {
            return standardized
        }
        if let resourceValues = try? standardized.resourceValues(forKeys: [.isDirectoryKey]),
           resourceValues.isDirectory == true {
            return standardized
        }
        return standardized.deletingLastPathComponent()
    }

    static func orderedUniqueDirectories(
        from pathURLs: [URL],
        excludingDescendantsOf excludedRootURLs: [URL] = []
    ) -> [String] {
        var seen: Set<String> = []
        var directories: [String] = []

        for url in pathURLs {
            let directoryURL = resolvedDirectoryURL(from: url)
            guard !excludedRootURLs.contains(where: { isSameOrDescendant(directoryURL, of: $0) }) else {
                continue
            }
            let path = canonicalDirectoryPath(directoryURL.path(percentEncoded: false))
            let dedupePath = canonicalDirectoryPath(
                normalizedComparisonURL(directoryURL).path(percentEncoded: false)
            )
            guard !path.isEmpty, !dedupePath.isEmpty else { continue }
            if seen.insert(dedupePath).inserted {
                directories.append(path)
            }
        }

        return directories
    }
}

enum TerminalDirectoryOpenTarget: String, CaseIterable {
    case androidStudio
    case antigravity
    case cursor
    case finder
    case ghostty
    case intellij
    case iterm2
    case terminal
    case tower
    case vscode
    case vscodeInline
    case warp
    case windsurf
    case xcode
    case zed

    struct DetectionEnvironment {
        let homeDirectoryPath: String
        let fileExistsAtPath: (String) -> Bool
        let isExecutableFileAtPath: (String) -> Bool
        let applicationPathForName: (String) -> String?

        static let live = DetectionEnvironment(
            homeDirectoryPath: FileManager.default.homeDirectoryForCurrentUser.path,
            fileExistsAtPath: { FileManager.default.fileExists(atPath: $0) },
            isExecutableFileAtPath: { FileManager.default.isExecutableFile(atPath: $0) },
            applicationPathForName: { NSWorkspace.shared.fullPath(forApplication: $0) }
        )
    }

    static var commandPaletteShortcutTargets: [Self] {
        Array(allCases)
    }

    static func availableTargets(in environment: DetectionEnvironment = .live) -> Set<Self> {
        Set(commandPaletteShortcutTargets.filter { $0.isAvailable(in: environment) })
    }

    var commandPaletteCommandId: String {
        "palette.terminalOpenDirectory.\(rawValue)"
    }

    var commandPaletteTitle: String {
        switch self {
        case .androidStudio:
            return String(localized: "menu.openInAndroidStudio", defaultValue: "Open Current Directory in Android Studio")
        case .antigravity:
            return String(localized: "menu.openInAntigravity", defaultValue: "Open Current Directory in Antigravity")
        case .cursor:
            return String(localized: "menu.openInCursor", defaultValue: "Open Current Directory in Cursor")
        case .finder:
            return String(localized: "menu.openInFinder", defaultValue: "Open Current Directory in Finder")
        case .ghostty:
            return String(localized: "menu.openInGhostty", defaultValue: "Open Current Directory in Ghostty")
        case .intellij:
            return String(localized: "menu.openInIntelliJ", defaultValue: "Open Current Directory in IntelliJ IDEA")
        case .iterm2:
            return String(localized: "menu.openInITerm2", defaultValue: "Open Current Directory in iTerm2")
        case .terminal:
            return String(localized: "menu.openInTerminal", defaultValue: "Open Current Directory in Terminal")
        case .tower:
            return String(localized: "menu.openInTower", defaultValue: "Open Current Directory in Tower")
        case .vscode:
            return String(localized: "menu.openInVSCodeDesktop", defaultValue: "Open Current Directory in VS Code")
        case .vscodeInline:
            return String(localized: "menu.openInVSCode", defaultValue: "Open Current Directory in VS Code (Inline)")
        case .warp:
            return String(localized: "menu.openInWarp", defaultValue: "Open Current Directory in Warp")
        case .windsurf:
            return String(localized: "menu.openInWindsurf", defaultValue: "Open Current Directory in Windsurf")
        case .xcode:
            return String(localized: "menu.openInXcode", defaultValue: "Open Current Directory in Xcode")
        case .zed:
            return String(localized: "menu.openInZed", defaultValue: "Open Current Directory in Zed")
        }
    }

    var commandPaletteKeywords: [String] {
        let common = ["terminal", "directory", "open", "ide"]
        switch self {
        case .androidStudio:
            return common + ["android", "studio"]
        case .antigravity:
            return common + ["antigravity"]
        case .cursor:
            return common + ["cursor"]
        case .finder:
            return common + ["finder", "file", "manager", "reveal"]
        case .ghostty:
            return common + ["ghostty", "terminal", "shell"]
        case .intellij:
            return common + ["intellij", "idea", "jetbrains"]
        case .iterm2:
            return common + ["iterm", "iterm2", "terminal", "shell"]
        case .terminal:
            return common + ["terminal", "shell"]
        case .tower:
            return common + ["tower", "git", "client"]
        case .vscode:
            return common + ["vs", "code", "visual", "studio", "desktop", "app"]
        case .vscodeInline:
            return common + ["vs", "code", "visual", "studio", "inline", "browser", "serve-web"]
        case .warp:
            return common + ["warp", "terminal", "shell"]
        case .windsurf:
            return common + ["windsurf"]
        case .xcode:
            return common + ["xcode", "apple"]
        case .zed:
            return common + ["zed"]
        }
    }

    func isAvailable(in environment: DetectionEnvironment = .live) -> Bool {
        guard let applicationPath = applicationPath(in: environment) else { return false }
        guard self == .vscodeInline else { return true }
        return VSCodeCLILaunchConfigurationBuilder.launchConfiguration(
            vscodeApplicationURL: URL(fileURLWithPath: applicationPath, isDirectory: true),
            isExecutableAtPath: environment.isExecutableFileAtPath
        ) != nil
    }

    func applicationURL(in environment: DetectionEnvironment = .live) -> URL? {
        guard let path = applicationPath(in: environment) else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func applicationPath(in environment: DetectionEnvironment) -> String? {
        for path in expandedCandidatePaths(in: environment) where environment.fileExistsAtPath(path) {
            return path
        }

        // Fall back to LaunchServices so apps outside the standard bundle paths
        // still appear in the command palette.
        for applicationName in applicationSearchNames {
            guard let resolvedPath = environment.applicationPathForName(applicationName),
                  environment.fileExistsAtPath(resolvedPath) else {
                continue
            }
            return resolvedPath
        }

        return nil
    }

    private func expandedCandidatePaths(in environment: DetectionEnvironment) -> [String] {
        let globalPrefix = "/Applications/"
        let userPrefix = "\(environment.homeDirectoryPath)/Applications/"
        var expanded: [String] = []

        for candidate in applicationBundlePathCandidates {
            expanded.append(candidate)
            if candidate.hasPrefix(globalPrefix) {
                let suffix = String(candidate.dropFirst(globalPrefix.count))
                expanded.append(userPrefix + suffix)
            }
        }

        return uniquePreservingOrder(expanded)
    }

    private var applicationSearchNames: [String] {
        uniquePreservingOrder(
            applicationBundlePathCandidates.map {
                URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent
            }
        )
    }

    private var applicationBundlePathCandidates: [String] {
        switch self {
        case .androidStudio:
            return ["/Applications/Android Studio.app"]
        case .antigravity:
            return ["/Applications/Antigravity.app"]
        case .cursor:
            return [
                "/Applications/Cursor.app",
                "/Applications/Cursor Preview.app",
                "/Applications/Cursor Nightly.app",
            ]
        case .finder:
            return ["/System/Library/CoreServices/Finder.app"]
        case .ghostty:
            return ["/Applications/Ghostty.app"]
        case .intellij:
            return ["/Applications/IntelliJ IDEA.app"]
        case .iterm2:
            return [
                "/Applications/iTerm.app",
                "/Applications/iTerm2.app",
            ]
        case .terminal:
            return ["/System/Applications/Utilities/Terminal.app"]
        case .tower:
            return ["/Applications/Tower.app"]
        case .vscode:
            return [
                "/Applications/Visual Studio Code.app",
                "/Applications/Code.app",
            ]
        case .vscodeInline:
            return [
                "/Applications/Visual Studio Code.app",
                "/Applications/Code.app",
            ]
        case .warp:
            return ["/Applications/Warp.app"]
        case .windsurf:
            return ["/Applications/Windsurf.app"]
        case .xcode:
            return ["/Applications/Xcode.app"]
        case .zed:
            return [
                "/Applications/Zed.app",
                "/Applications/Zed Preview.app",
                "/Applications/Zed Nightly.app",
            ]
        }
    }

    private func uniquePreservingOrder(_ paths: [String]) -> [String] {
        var seen: Set<String> = []
        var deduped: [String] = []
        for path in paths where seen.insert(path).inserted {
            deduped.append(path)
        }
        return deduped
    }
}

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

struct VSCodeCLILaunchConfiguration {
    let executableURL: URL
    let argumentsPrefix: [String]
    let environment: [String: String]
}

enum VSCodeCLILaunchConfigurationBuilder {
    static func launchConfiguration(
        vscodeApplicationURL: URL,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        isExecutableAtPath: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> VSCodeCLILaunchConfiguration? {
        let contentsURL = vscodeApplicationURL.appendingPathComponent("Contents", isDirectory: true)
        let codeTunnelURL = contentsURL.appendingPathComponent("Resources/app/bin/code-tunnel", isDirectory: false)
        guard isExecutableAtPath(codeTunnelURL.path) else { return nil }

        var environment = baseEnvironment
        environment["ELECTRON_RUN_AS_NODE"] = "1"
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

        return VSCodeCLILaunchConfiguration(
            executableURL: codeTunnelURL,
            argumentsPrefix: [],
            environment: environment
        )
    }
}

final class VSCodeServeWebController {
    static let shared = VSCodeServeWebController()
    private static let serveWebStartupTimeoutSeconds: TimeInterval = 60

    private let queue = DispatchQueue(label: "cmux.vscode.serveWeb")
    private let launchQueue = DispatchQueue(label: "cmux.vscode.serveWeb.launch")
    private let launchProcessOverride: ((URL, UInt64) -> (process: Process, url: URL)?)?
    private var serveWebProcess: Process?
    private var launchingProcess: Process?
    private var connectionTokenFilesByProcessID: [ObjectIdentifier: URL] = [:]
    private var serveWebURL: URL?
    private var pendingCompletions: [(generation: UInt64, completion: (URL?) -> Void)] = []
    private var isLaunching = false
    private var activeLaunchGeneration: UInt64?
    private var lifecycleGeneration: UInt64 = 0
#if DEBUG
    private var testingTrackedProcesses: [Process] = []
#endif

    private init(launchProcessOverride: ((URL, UInt64) -> (process: Process, url: URL)?)? = nil) {
        self.launchProcessOverride = launchProcessOverride
    }

#if DEBUG
    static func makeForTesting(
        launchProcessOverride: @escaping (URL, UInt64) -> (process: Process, url: URL)?
    ) -> VSCodeServeWebController {
        VSCodeServeWebController(launchProcessOverride: launchProcessOverride)
    }

    func trackConnectionTokenFileForTesting(
        _ connectionTokenFileURL: URL,
        setAsLaunchingProcess: Bool = false,
        setAsServeWebProcess: Bool = false
    ) {
        let process = Process()
        queue.sync {
            if setAsLaunchingProcess {
                self.launchingProcess = process
            }
            if setAsServeWebProcess {
                self.serveWebProcess = process
            }
            if !setAsLaunchingProcess && !setAsServeWebProcess {
                self.testingTrackedProcesses.append(process)
            }
            self.connectionTokenFilesByProcessID[ObjectIdentifier(process)] = connectionTokenFileURL
        }
    }
#endif

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
        let (processes, tokenFileURLs, completions): ([Process], [URL], [(URL?) -> Void]) = queue.sync {
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
#if DEBUG
            self.testingTrackedProcesses.removeAll()
#endif
            var tokenFileURLs = processes.compactMap {
                self.connectionTokenFilesByProcessID.removeValue(forKey: ObjectIdentifier($0))
            }
            tokenFileURLs.append(contentsOf: self.connectionTokenFilesByProcessID.values)
            self.connectionTokenFilesByProcessID.removeAll()
            self.serveWebURL = nil
            let completions = self.pendingCompletions.map(\.completion)
            self.pendingCompletions.removeAll()
            return (processes, tokenFileURLs, completions)
        }

        for tokenFileURL in tokenFileURLs {
            Self.removeConnectionTokenFile(at: tokenFileURL)
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

        guard let connectionTokenFileURL = Self.makeConnectionTokenFile() else {
            return nil
        }

        let process = Process()
        process.executableURL = launchConfiguration.executableURL
        process.arguments = launchConfiguration.argumentsPrefix + [
            "serve-web",
            "--accept-server-license-terms",
            "--host", "127.0.0.1",
            "--port", "0",
            "--connection-token-file", connectionTokenFileURL.path,
        ]
        process.environment = launchConfiguration.environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let collector = ServeWebOutputCollector()
        let outputReader: (FileHandle) -> Void = { fileHandle in
            let data = fileHandle.availableData
            guard !data.isEmpty else {
                fileHandle.readabilityHandler = nil
                return
            }
            collector.append(data)
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
                if let tokenFileURL = self.connectionTokenFilesByProcessID.removeValue(
                    forKey: ObjectIdentifier(terminatedProcess)
                ) {
                    Self.removeConnectionTokenFile(at: tokenFileURL)
                }
            }
        }

        let didStart: Bool = queue.sync {
            guard self.lifecycleGeneration == expectedGeneration,
                  self.activeLaunchGeneration == expectedGeneration else {
                return false
            }
            self.launchingProcess = process
            self.connectionTokenFilesByProcessID[ObjectIdentifier(process)] = connectionTokenFileURL
            do {
                try process.run()
                return true
            } catch {
                if self.launchingProcess === process {
                    self.launchingProcess = nil
                }
                if let tokenFileURL = self.connectionTokenFilesByProcessID.removeValue(
                    forKey: ObjectIdentifier(process)
                ) {
                    Self.removeConnectionTokenFile(at: tokenFileURL)
                }
                return false
            }
        }
        guard didStart else {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            Self.removeConnectionTokenFile(at: connectionTokenFileURL)
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
                    if let tokenFileURL = self.connectionTokenFilesByProcessID.removeValue(
                        forKey: ObjectIdentifier(process)
                    ) {
                        Self.removeConnectionTokenFile(at: tokenFileURL)
                    }
                }
            }
            return nil
        }

        return (process, serveWebURL)
    }

    private static func drainAvailableOutput(from fileHandle: FileHandle, collector: ServeWebOutputCollector) {
        while true {
            let data = fileHandle.availableData
            guard !data.isEmpty else { return }
            collector.append(data)
        }
    }

    private static func randomConnectionToken() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    private static func makeConnectionTokenFile() -> URL? {
        let token = randomConnectionToken()
        let tokenFileName = "cmux-vscode-token-\(UUID().uuidString)"
        let tokenFileURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(tokenFileName, isDirectory: false)
        guard let tokenData = token.data(using: .utf8) else { return nil }

        let fileDescriptor = open(tokenFileURL.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard fileDescriptor >= 0 else { return nil }
        defer { _ = close(fileDescriptor) }

        let wroteAllBytes = tokenData.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return false }
            return write(fileDescriptor, baseAddress, rawBuffer.count) == rawBuffer.count
        }
        guard wroteAllBytes else {
            removeConnectionTokenFile(at: tokenFileURL)
            return nil
        }

        return tokenFileURL
    }

    private static func removeConnectionTokenFile(at url: URL) {
        try? FileManager.default.removeItem(at: url)
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

enum WorkspaceShortcutMapper {
    /// Maps numbered workspace shortcuts to a zero-based workspace index.
    /// 1...8 target fixed indices; 9 always targets the last workspace.
    static func workspaceIndex(forDigit digit: Int, workspaceCount: Int) -> Int? {
        guard workspaceCount > 0 else { return nil }
        guard (1...9).contains(digit) else { return nil }

        if digit == 9 {
            return workspaceCount - 1
        }

        let index = digit - 1
        return index < workspaceCount ? index : nil
    }

    /// Returns the primary digit badge to display for a workspace row.
    /// Picks the lowest digit that maps to that row index.
    static func digitForWorkspace(at index: Int, workspaceCount: Int) -> Int? {
        guard index >= 0 && index < workspaceCount else { return nil }
        for digit in 1...9 {
            if workspaceIndex(forDigit: digit, workspaceCount: workspaceCount) == index {
                return digit
            }
        }
        return nil
    }
}
