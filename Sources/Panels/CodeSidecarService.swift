import AppKit
import CMUXMobileCore
import CmuxFoundation
import Darwin
import Foundation
import Security
import WebKit

enum BrowserPanelPurpose: String, Codable, Equatable, Sendable {
    case standard
    case code
}

enum ContextualSurfaceCreationKind: Equatable, Sendable {
    case terminal
    case code

    static func resolve(panel: (any Panel)?) -> Self {
        guard let browser = panel as? BrowserPanel, browser.purpose == .code else {
            return .terminal
        }
        return .code
    }
}

struct CodeWebThemeSnapshot: Equatable {
    static let sansFontFamily = "-apple-system, BlinkMacSystemFont, \"SF Pro Text\", \"Helvetica Neue\", sans-serif"
    static let monoFontFamily = "\"SFMono-Regular\", \"SF Mono\", ui-monospace, Menlo, monospace"

    let isDark: Bool
    let variables: [String: String]

    init(
        terminalTheme: TerminalTheme,
        backgroundOpacity: Double = 1
    ) {
        let foreground = terminalTheme.foreground
        let primary = terminalTheme.palette.indices.contains(4)
            ? terminalTheme.palette[4]
            : terminalTheme.cursor
        let success = terminalTheme.palette.indices.contains(2)
            ? terminalTheme.palette[2]
            : foreground
        let destructive = terminalTheme.palette.indices.contains(1)
            ? terminalTheme.palette[1]
            : foreground
        let primaryColor = NSColor(hex: primary) ?? .controlAccentColor
        let primaryForeground = cmuxReadableForegroundNSColor(
            on: primaryColor,
            opacity: 1
        ).hexString()
        let resolvedBackground = NSColor(hex: terminalTheme.background) ?? .textBackgroundColor
        let clampedBackgroundOpacity = GhosttyBackgroundTheme.clampedOpacity(backgroundOpacity)

        isDark = !resolvedBackground.isLightColor
        variables = [
            "--cmux-code-canvas": "transparent",
            "--cmux-code-font-mono": Self.monoFontFamily,
            "--cmux-code-font-sans": Self.sansFontFamily,
            "--cmux-ghostty-background": terminalTheme.background,
            "--cmux-ghostty-background-opacity": String(
                format: "%.3f",
                locale: Locale(identifier: "en_US_POSIX"),
                Double(clampedBackgroundOpacity)
            ),
            "--cmux-ghostty-cursor": terminalTheme.cursor,
            "--cmux-ghostty-destructive": destructive,
            "--cmux-ghostty-foreground": foreground,
            "--cmux-ghostty-primary": primary,
            "--cmux-ghostty-primary-foreground": primaryForeground,
            "--cmux-ghostty-selection": terminalTheme.selectionBackground,
            "--cmux-ghostty-success": success,
            "--font-mono": Self.monoFontFamily,
            "--font-sans": Self.sansFontFamily,
        ]
    }

    @MainActor
    static func current() -> CodeWebThemeSnapshot {
        let app = GhosttyApp.shared
        let terminalTheme = TerminalTheme.currentMacTerminalThemeSnapshot()
        return CodeWebThemeSnapshot(
            terminalTheme: terminalTheme,
            backgroundOpacity: app.defaultBackgroundOpacity
        )
    }

    func applyingJavaScript() -> String? {
        let payload: [String: Any] = [
            "isDark": isDark,
            "variables": variables,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return """
        (() => {
          const theme = \(json);
          const root = document.documentElement;
          if (!root) return false;
          root.dataset.cmuxGhosttyTheme = "true";
          root.classList.toggle("dark", theme.isDark);
          root.style.colorScheme = theme.isDark ? "dark" : "light";
          for (const [name, value] of Object.entries(theme.variables)) {
            root.style.setProperty(name, value);
          }
          window.dispatchEvent(new CustomEvent("cmux:ghostty-theme-change", { detail: theme }));
          return true;
        })()
        """
    }
}

private enum CodeSidecarError: LocalizedError {
    case bootstrapEncoding
    case bootstrapTokenGeneration(OSStatus)
    case missingResource(String)
    case noLoopbackPort
    case launchFailed

    var errorDescription: String? {
        switch self {
        case .bootstrapEncoding: return "The Code server bootstrap could not be encoded"
        case .bootstrapTokenGeneration(let status):
            return "The Code server bootstrap token could not be generated (status \(status))"
        case .missingResource(let name): return "Missing bundled Code resource: \(name)"
        case .noLoopbackPort: return "No loopback port was available"
        case .launchFailed: return "The Code server did not start"
        }
    }
}

@MainActor
final class CodeSidecarService {
    static let shared = CodeSidecarService()

    private struct RunningProcess {
        let process: Process
        let url: URL
        let logHandle: FileHandle
    }

    private var activeSurfaceIDs = Set<UUID>()
    private var running: RunningProcess?
    private var startupTask: Task<URL, Error>?

    static func launcherURL(bundle: Bundle = .main) -> URL? {
        bundle.url(
            forResource: "code",
            withExtension: "html",
            subdirectory: "markdown-viewer/webviews-app"
        )
    }

    func mount(surfaceID: UUID, workingDirectory: String?) async throws -> URL {
        activeSurfaceIDs.insert(surfaceID)
        if let running, running.process.isRunning {
            return running.url
        }
        if let running {
            running.logHandle.closeFile()
            self.running = nil
        }

        let task: Task<URL, Error>
        if let startupTask {
            task = startupTask
        } else {
            let newTask = Task { @MainActor [weak self] in
                guard let self else { throw CancellationError() }
                return try await self.start(workingDirectory: workingDirectory)
            }
            startupTask = newTask
            task = newTask
        }

        do {
            let url = try await task.value
            startupTask = nil
            guard activeSurfaceIDs.contains(surfaceID) else {
                if activeSurfaceIDs.isEmpty {
                    stop()
                }
                throw CancellationError()
            }
            return url
        } catch {
            startupTask = nil
            activeSurfaceIDs.remove(surfaceID)
            throw error
        }
    }

    func release(surfaceID: UUID) {
        activeSurfaceIDs.remove(surfaceID)
        guard activeSurfaceIDs.isEmpty else { return }
        startupTask?.cancel()
        startupTask = nil
        stop()
    }

    func stop() {
        activeSurfaceIDs.removeAll()
        startupTask?.cancel()
        startupTask = nil
        guard let running else { return }
        self.running = nil
        if running.process.isRunning {
            running.process.terminate()
        }
        running.logHandle.closeFile()
    }

    private func start(workingDirectory: String?) async throws -> URL {
        guard let resources = Bundle.main.resourceURL else {
            throw CodeSidecarError.missingResource("Resources")
        }
        let executable = resources.appendingPathComponent("bin/cmux-code-sidecar", isDirectory: false)
        let staticDirectory = resources.appendingPathComponent("code-sidecar/client", isDirectory: true)
        let architecture = Self.processArchitecture
        let resourceMonitor = resources.appendingPathComponent(
            "code-sidecar/resource-monitor/darwin-\(architecture)/cmux-code-resource-monitor",
            isDirectory: false
        )
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw CodeSidecarError.missingResource(executable.lastPathComponent)
        }
        guard FileManager.default.fileExists(atPath: staticDirectory.appendingPathComponent("index.html").path) else {
            throw CodeSidecarError.missingResource("Code client")
        }
        guard FileManager.default.isExecutableFile(atPath: resourceMonitor.path) else {
            throw CodeSidecarError.missingResource(resourceMonitor.lastPathComponent)
        }

        let root = try Self.dataDirectory()
        let port = try Self.allocateLoopbackPort()
        let healthURL = URL(string: "http://127.0.0.1:\(port)/")!
        let bootstrapToken = try Self.makeBootstrapToken()
        let authenticatedURL = try Self.authenticatedURL(port: port, bootstrapToken: bootstrapToken)
        let bootstrapEnvelope = try Self.bootstrapEnvelope(
            port: port,
            dataDirectory: root,
            resourceMonitor: resourceMonitor,
            bootstrapToken: bootstrapToken
        )
        let logURL = root.appendingPathComponent("server.log", isDirectory: false)
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        let logHandle = try FileHandle(forWritingTo: logURL)
        try logHandle.seekToEnd()

        let process = Process()
        process.executableURL = executable
        let bootstrapPipe = Pipe()
        var arguments = [
            "start",
            "--mode", "desktop",
            "--host", "127.0.0.1",
            "--port", String(port),
            "--base-dir", root.path,
            "--no-browser",
            "--bootstrap-fd", "0",
        ]
        if let workingDirectory = Self.automaticProjectDirectory(workingDirectory) {
            arguments.append(contentsOf: ["--auto-bootstrap-project-from-cwd", workingDirectory])
        }
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_CODE_STATIC_DIR"] = staticDirectory.path
        environment["CMUX_CODE_RESOURCE_MONITOR_PATH"] = resourceMonitor.path
        environment["NO_COLOR"] = "1"
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let inheritedPath = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = "\(home)/.local/bin:\(home)/.bun/bin:/opt/homebrew/bin:/usr/local/bin:\(inheritedPath)"
        process.environment = environment
        process.standardInput = bootstrapPipe
        process.standardOutput = logHandle
        process.standardError = logHandle

        do {
            try process.run()
            try bootstrapPipe.fileHandleForWriting.write(contentsOf: bootstrapEnvelope)
            try bootstrapPipe.fileHandleForWriting.close()
            try await Self.waitUntilReady(process: process, url: healthURL)
            try Task.checkCancellation()
            guard !activeSurfaceIDs.isEmpty else { throw CancellationError() }
            running = RunningProcess(process: process, url: authenticatedURL, logHandle: logHandle)
            return authenticatedURL
        } catch {
            try? bootstrapPipe.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            logHandle.closeFile()
            throw error
        }
    }

    private static func waitUntilReady(process: Process, url: URL) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 0.4
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            guard process.isRunning else { throw CodeSidecarError.launchFailed }
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 0.4
                let (_, response) = try await session.data(for: request)
                if let response = response as? HTTPURLResponse, (200..<400).contains(response.statusCode) {
                    return
                }
            } catch {
                // Startup commonly refuses the first few connections while the database opens.
            }
            try await ContinuousClock().sleep(for: .milliseconds(100))
        }
        throw CodeSidecarError.launchFailed
    }

    private static var processArchitecture: String {
#if arch(arm64)
        "arm64"
#else
        "x64"
#endif
    }

    static func automaticProjectDirectory(_ candidate: String?) -> String? {
        guard let candidate = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
              !candidate.isEmpty else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        let directory = URL(fileURLWithPath: candidate, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let home = FileManager.default.homeDirectoryForCurrentUser
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard directory.path != "/", directory.path != home.path else { return nil }
        return directory.path
    }

    static func bootstrapEnvelope(
        port: Int,
        dataDirectory: URL,
        resourceMonitor: URL,
        bootstrapToken: String
    ) throws -> Data {
        let payload: [String: Any] = [
            "mode": "desktop",
            "noBrowser": true,
            "port": port,
            "t3Home": dataDirectory.path,
            "host": "127.0.0.1",
            "desktopBootstrapToken": bootstrapToken,
            "tailscaleServeEnabled": false,
            "tailscaleServePort": 443,
            "resourceMonitorPath": resourceMonitor.path,
        ]
        guard var data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            throw CodeSidecarError.bootstrapEncoding
        }
        data.append(0x0A)
        return data
    }

    static func authenticatedURL(port: Int, bootstrapToken: String) throws -> URL {
        guard var components = URLComponents(string: "http://127.0.0.1:\(port)/pair") else {
            throw CodeSidecarError.bootstrapEncoding
        }
        components.fragment = "token=\(bootstrapToken)"
        guard let url = components.url else {
            throw CodeSidecarError.bootstrapEncoding
        }
        return url
    }

    private static func makeBootstrapToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw CodeSidecarError.bootstrapTokenGeneration(status)
        }
        return Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func dataDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let bundleComponent = (Bundle.main.bundleIdentifier ?? "cmux")
            .replacingOccurrences(of: "/", with: "_")
        let directory = base
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("code", isDirectory: true)
            .appendingPathComponent(bundleComponent, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func allocateLoopbackPort() throws -> Int {
        for _ in 0..<8 {
            let descriptor = socket(AF_INET, SOCK_STREAM, 0)
            guard descriptor >= 0 else { break }
            defer { close(descriptor) }

            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = 0
            address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            let bindResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bindResult == 0 else { continue }

            var bound = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let nameResult = withUnsafeMutablePointer(to: &bound) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getsockname(descriptor, $0, &length)
                }
            }
            guard nameResult == 0 else { continue }
            let port = Int(UInt16(bigEndian: bound.sin_port))
            if (1...65535).contains(port) { return port }
        }
        throw CodeSidecarError.noLoopbackPort
    }
}

@MainActor
final class CodeSurfaceMessageHandler: NSObject, WKScriptMessageHandler {
    static let name = "cmuxCode"
    weak var panel: BrowserPanel?

    init(panel: BrowserPanel) {
        self.panel = panel
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame,
              let body = message.body as? [String: Any],
              body["type"] as? String == "mount",
              let panel,
              panel.purpose == .code else { return }
        panel.mountCodeSidecar()
    }
}
