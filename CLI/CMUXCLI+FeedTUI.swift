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


// MARK: - Feed TUI command
extension CMUXCLI {
    struct FeedTUIOption {
        let id: String
        let label: String
    }

    struct FeedTUIQuestion {
        let multiSelect: Bool
        let options: [FeedTUIOption]
    }

    struct FeedTUIItem {
        let id: String
        let requestId: String?
        let source: String
        let kind: String
        let status: String
        let createdAt: Date?
        let title: String
        let detail: String
        let toolInputCapabilitiesJSON: String
        let defaultMode: String?
        let questionMultiSelect: Bool
        let questionOptions: [FeedTUIOption]
        let questions: [FeedTUIQuestion]

        var isPending: Bool {
            status == "pending"
        }

        var canResolve: Bool {
            isPending && requestId != nil &&
                (kind == "permissionRequest" || kind == "exitPlan" || kind == "question")
        }

        static func parse(_ dict: [String: Any]) -> FeedTUIItem? {
            guard let id = dict["id"] as? String,
                  dict["workstream_id"] is String,
                  let source = dict["source"] as? String,
                  let kind = dict["kind"] as? String,
                  let status = dict["status"] as? String else {
                return nil
            }
            let title = (dict["title"] as? String)
                ?? Self.defaultTitle(kind: kind, dict: dict)
            let detail = Self.detail(kind: kind, dict: dict)
            let createdAt = Self.dateValue(
                dict["created_at"]
                    ?? dict["createdAt"]
                    ?? dict["timestamp"]
                    ?? dict["time"]
            )
            let options: [FeedTUIOption] = (dict["question_options"] as? [[String: Any]])?.compactMap { option in
                guard let id = option["id"] as? String,
                      let label = option["label"] as? String else {
                    return nil
                }
                return FeedTUIOption(id: id, label: label)
            } ?? []
            let questions = Self.questions(dict: dict, fallbackOptions: options)
            return FeedTUIItem(
                id: id,
                requestId: dict["request_id"] as? String,
                source: source,
                kind: kind,
                status: status,
                createdAt: createdAt,
                title: title,
                detail: detail,
                toolInputCapabilitiesJSON: (dict["tool_input_capabilities"] as? String)
                    ?? (dict["tool_input"] as? String)
                    ?? "",
                defaultMode: dict["default_mode"] as? String,
                questionMultiSelect: (dict["question_multi_select"] as? Bool) ?? false,
                questionOptions: options,
                questions: questions
            )
        }

        private static func questions(dict: [String: Any], fallbackOptions: [FeedTUIOption]) -> [FeedTUIQuestion] {
            if let rawQuestions = dict["questions"] as? [[String: Any]] {
                let parsed = rawQuestions.compactMap { raw -> FeedTUIQuestion? in
                    let prompt = (raw["prompt"] as? String)
                        ?? (raw["question"] as? String)
                        ?? (raw["header"] as? String)
                        ?? ""
                    let options = (raw["options"] as? [[String: Any]])?.compactMap { option -> FeedTUIOption? in
                        guard let id = option["id"] as? String,
                              let label = option["label"] as? String else {
                            return nil
                        }
                        return FeedTUIOption(id: id, label: label)
                    } ?? []
                    guard !prompt.isEmpty || !options.isEmpty else { return nil }
                    return FeedTUIQuestion(
                        multiSelect: (raw["multi_select"] as? Bool) ?? (raw["multiSelect"] as? Bool) ?? false,
                        options: options
                    )
                }
                if !parsed.isEmpty {
                    return parsed
                }
            }
            return [
                FeedTUIQuestion(
                    multiSelect: (dict["question_multi_select"] as? Bool) ?? false,
                    options: fallbackOptions
                )
            ]
        }

        private static func defaultTitle(kind: String, dict: [String: Any]) -> String {
            switch kind {
            case "permissionRequest":
                return "Permission: \((dict["tool_name"] as? String) ?? "tool")"
            case "exitPlan":
                return "Plan"
            case "question":
                return "Question"
            default:
                return kind
            }
        }

        private static func detail(kind: String, dict: [String: Any]) -> String {
            switch kind {
            case "permissionRequest":
                let tool = (dict["tool_name"] as? String) ?? "tool"
                let input = (dict["tool_input"] as? String) ?? ""
                return input.isEmpty ? tool : "\(tool): \(input)"
            case "exitPlan":
                return (dict["plan_summary"] as? String)
                    ?? (dict["plan"] as? String)
                    ?? "Review the proposed plan"
            case "question":
                return (dict["question_prompt"] as? String) ?? "Answer the agent question"
            default:
                return (dict["text"] as? String)
                    ?? (dict["reason"] as? String)
                    ?? ((dict["cwd"] as? String) ?? "")
            }
        }

        private static func dateValue(_ rawValue: Any?) -> Date? {
            if let date = rawValue as? Date {
                return date
            }

            if let number = rawValue as? NSNumber {
                return dateFromTimeInterval(number.doubleValue)
            }

            if let value = rawValue as? Double {
                return dateFromTimeInterval(value)
            }

            if let value = rawValue as? Int {
                return dateFromTimeInterval(Double(value))
            }

            guard let value = rawValue as? String,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }

            let isoFormatter = ISO8601DateFormatter()
            if let date = isoFormatter.date(from: value) {
                return date
            }

            let fractionalFormatter = ISO8601DateFormatter()
            fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractionalFormatter.date(from: value) {
                return date
            }

            if let numericValue = Double(value) {
                return dateFromTimeInterval(numericValue)
            }

            return nil
        }

        private static func dateFromTimeInterval(_ value: Double) -> Date? {
            guard value.isFinite, value > 0 else { return nil }
            let seconds = value > 10_000_000_000 ? value / 1_000 : value
            return Date(timeIntervalSince1970: seconds)
        }
    }

    enum FeedTUIKey: Equatable {
        case tick
        case up
        case down
        case enter
        case quit
        case refresh
        case deny
        case feedback
        case once
        case always
        case all
        case bypass
        case manual
        case autoAccept
        case ultraplan
        case number(Int)
        case ignored
    }

    private static let openTUIFeedCoreVersion = "0.1.106"

    private enum FeedTUIImplementation {
        case automatic
        case openTUI
        case legacy
        case help
    }

    func runFeedTUI(arguments: [String], socketPath: String, socketPassword: String?) throws {
        let resolvedSocketPassword = SocketPasswordResolver.resolve(
            explicit: socketPassword,
            socketPath: socketPath
        )
        let implementation = try parseFeedTUIImplementation(arguments: arguments)
        if implementation == .help { return }
        if implementation == .legacy || ProcessInfo.processInfo.environment["CMUX_FEED_TUI_LEGACY"] == "1" {
            try runLegacyFeedTUI(socketPath: socketPath, socketPassword: resolvedSocketPassword)
            return
        }
        if implementation == .openTUI {
            try runOpenTUIFeedTUI(socketPath: socketPath, socketPassword: resolvedSocketPassword)
            return
        }

        do {
            try runOpenTUIFeedTUI(socketPath: socketPath, socketPassword: resolvedSocketPassword)
        } catch {
            fputs(
                "cmux feed tui: OpenTUI unavailable (\(error)); falling back to legacy TUI.\n",
                stderr
            )
            try runLegacyFeedTUI(socketPath: socketPath, socketPassword: resolvedSocketPassword)
        }
    }

    private func parseFeedTUIImplementation(arguments: [String]) throws -> FeedTUIImplementation {
        var implementation = FeedTUIImplementation.automatic
        for argument in arguments {
            switch argument {
            case "--opentui":
                guard implementation != .legacy else {
                    throw CLIError(message: "cmux feed tui: choose only one TUI implementation")
                }
                implementation = .openTUI
            case "--legacy":
                guard implementation != .openTUI else {
                    throw CLIError(message: "cmux feed tui: choose only one TUI implementation")
                }
                implementation = .legacy
            case "--help", "-h":
                print("Usage: cmux feed tui [--opentui|--legacy]")
                return .help
            default:
                throw CLIError(message: "cmux feed tui: unknown argument \(argument)")
            }
        }
        return implementation
    }

    private func runOpenTUIFeedTUI(socketPath: String, socketPassword: String?) throws {
        guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 else {
            throw CLIError(message: "cmux feed tui requires an interactive terminal")
        }
        guard let bunPath = resolveBunExecutable() else {
            throw CLIError(message: "Bun is required for the OpenTUI Feed")
        }

        fputs("cmux feed tui: preparing OpenTUI Feed...\n", stderr)
        fflush(stderr)
        let appDirectory = try prepareOpenTUIFeedApp(bunPath: bunPath)
        let sourceURL = appDirectory.appendingPathComponent("index.ts", isDirectory: false)
        fputs("cmux feed tui: starting OpenTUI Feed.\n", stderr)
        fflush(stderr)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: bunPath)
        process.arguments = [sourceURL.path]
        process.currentDirectoryURL = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath; environment.removeValue(forKey: "CMUX_SOCKET")
        if let socketPassword {
            environment["CMUX_SOCKET_PASSWORD"] = socketPassword
        }
        environment["OTUI_USE_CONSOLE"] = environment["OTUI_USE_CONSOLE"] ?? "0"
        environment["OTUI_USE_ALTERNATE_SCREEN"] = "1"
        environment["CMUX_FEED_TUI_PATH"] = "opentui"
        process.environment = environment
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError

        let originalForegroundProcessGroup = tcgetpgrp(STDIN_FILENO)
        var didForegroundChild = false
        try process.run()
        if originalForegroundProcessGroup > 0 {
            let childProcessGroup = getpgid(process.processIdentifier)
            if childProcessGroup > 0 && childProcessGroup != originalForegroundProcessGroup {
                try setTerminalForegroundProcessGroup(childProcessGroup)
                _ = Darwin.kill(-childProcessGroup, SIGCONT)
                didForegroundChild = true
            }
        }
        defer {
            if didForegroundChild {
                try? setTerminalForegroundProcessGroup(originalForegroundProcessGroup)
            }
        }
        process.waitUntilExit()
        if process.terminationStatus == 0 || process.terminationStatus == 130 || (process.terminationReason == .uncaughtSignal && process.terminationStatus == SIGINT) { return }
        throw CLIError(message: "OpenTUI Feed exited with status \(process.terminationStatus)")
    }

    func setTerminalForegroundProcessGroup(_ processGroup: pid_t) throws {
        let previousHandler = signal(SIGTTOU, SIG_IGN)
        defer { _ = signal(SIGTTOU, previousHandler) }
        guard tcsetpgrp(STDIN_FILENO, processGroup) == 0 else {
            throw CLIError(message: "cmux feed tui: failed to foreground OpenTUI process: \(String(cString: strerror(errno)))")
        }
    }

    private func resolveBunExecutable() -> String? {
        if let path = ProcessInfo.processInfo.environment["CMUX_FEED_TUI_BUN_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty,
           FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        if let path = resolveExecutableInPath("bun") {
            return path
        }
        let homePath = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        for path in [
            "\(homePath)/.bun/bin/bun",
            "\(homePath)/.local/bin/bun",
            "/opt/homebrew/bin/bun",
            "/usr/local/bin/bun",
        ] {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    private func prepareOpenTUIFeedApp(bunPath: String) throws -> URL {
        let fileManager = FileManager.default
        let homePath = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let appDirectory = URL(fileURLWithPath: homePath, isDirectory: true)
            .appendingPathComponent(".cmuxterm", isDirectory: true)
            .appendingPathComponent("feed-tui-opentui", isDirectory: true)
        try fileManager.createDirectory(at: appDirectory, withIntermediateDirectories: true)

        let packageURL = appDirectory.appendingPathComponent("package.json", isDirectory: false)
        let sourceURL = appDirectory.appendingPathComponent("index.ts", isDirectory: false)
        let packageSource = """
        {
          "private": true,
          "type": "module",
          "dependencies": {
            "@opentui/core": "\(Self.openTUIFeedCoreVersion)"
          }
        }
        """
        try writeFileIfChanged(packageSource, to: packageURL)
        try writeFileIfChanged(try bundledOpenTUIFeedSource(), to: sourceURL)

        let installedPackageURL = appDirectory
            .appendingPathComponent("node_modules", isDirectory: true)
            .appendingPathComponent("@opentui", isDirectory: true)
            .appendingPathComponent("core", isDirectory: true)
            .appendingPathComponent("package.json", isDirectory: false)
        if !fileManager.fileExists(atPath: installedPackageURL.path)
            || installedOpenTUIVersion(at: installedPackageURL) != Self.openTUIFeedCoreVersion {
            fputs("cmux feed tui: installing @opentui/core \(Self.openTUIFeedCoreVersion)...\n", stderr)
            fflush(stderr)
            try installOpenTUIFeedDependencies(bunPath: bunPath, appDirectory: appDirectory)
        }
        return appDirectory
    }

    private func bundledOpenTUIFeedSource() throws -> String {
        let fileManager = FileManager.default
        if let resourceURL = Bundle.main.resourceURL {
            let url = resourceURL
                .appendingPathComponent("feed-tui", isDirectory: true)
                .appendingPathComponent("index.ts", isDirectory: false)
            if fileManager.fileExists(atPath: url.path),
               let contents = try? String(contentsOf: url, encoding: .utf8) {
                return contents
            }
        }

        let devURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("feed-tui", isDirectory: true)
            .appendingPathComponent("index.ts", isDirectory: false)
        if fileManager.fileExists(atPath: devURL.path),
           let contents = try? String(contentsOf: devURL, encoding: .utf8) {
            return contents
        }

        throw CLIError(message: "bundled OpenTUI Feed source not found")
    }

    private func writeFileIfChanged(_ contents: String, to url: URL) throws {
        let existing = try? String(contentsOf: url, encoding: .utf8)
        guard existing != contents else { return }
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func installedOpenTUIVersion(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["version"] as? String else {
            return nil
        }
        return version
    }

    private func installOpenTUIFeedDependencies(bunPath: String, appDirectory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: bunPath)
        process.arguments = ["install", "--silent"]
        process.currentDirectoryURL = appDirectory
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading
        var stdoutData = Data()
        var stderrData = Data()
        let drainGroup = DispatchGroup()
        drainGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            stdoutData = ProcessPipeReader.readDataToEndOfFileOrEmpty(from: stdoutHandle)
            drainGroup.leave()
        }
        drainGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            stderrData = ProcessPipeReader.readDataToEndOfFileOrEmpty(from: stderrHandle)
            drainGroup.leave()
        }

        try process.run()
        process.waitUntilExit()
        drainGroup.wait()
        guard process.terminationStatus == 0 else {
            let stderrText = String(data: stderrData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let stdoutText = String(data: stdoutData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw CLIError(message: stderrText.isEmpty ? (stdoutText.isEmpty ? "bun install failed" : stdoutText) : stderrText)
        }
    }

    private func runLegacyFeedTUI(socketPath: String, socketPassword: String?) throws {
        guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 else {
            throw CLIError(message: "cmux feed tui requires an interactive terminal")
        }

        let client = SocketClient(path: socketPath)
        try client.connect()
        try authenticateClientIfNeeded(client, explicitPassword: socketPassword, socketPath: socketPath)

        var rawMode = TerminalRawMode()
        guard rawMode != nil else {
            throw CLIError(message: "Failed to enter terminal raw mode")
        }

        print("\u{001B}[?1049h\u{001B}[?25l", terminator: "")
        defer {
            rawMode?.restore()
            print("\u{001B}[?25h\u{001B}[?1049l", terminator: "")
            fflush(stdout)
        }

        var selectedIndex = 0
        var selectedItemID: String?
        var scrollOffset = 0
        var statusLine = ""
        var selectedQuestionOptions: [String: Set<String>] = [:]
        var didWriteReadyMarker = false
        while true {
            let items = try feedTUIItems(client: client)
            if let selectedItemID,
               let updatedIndex = items.firstIndex(where: { $0.id == selectedItemID }) {
                selectedIndex = updatedIndex
            } else if selectedIndex >= items.count {
                selectedIndex = max(items.count - 1, 0)
            }
            selectedItemID = feedTUIItem(in: items, at: selectedIndex)?.id
            scrollOffset = adjustedFeedTUIScrollOffset(
                itemCount: items.count,
                selectedIndex: selectedIndex,
                scrollOffset: scrollOffset
            )
            renderFeedTUI(
                items: items,
                selectedIndex: selectedIndex,
                scrollOffset: scrollOffset,
                statusLine: statusLine
            )
            if !didWriteReadyMarker {
                writeFeedTUIReadyMarker(stage: "legacy-ready")
                didWriteReadyMarker = true
            }
            statusLine = ""

            let key = readFeedTUIKey(timeoutMilliseconds: 1_000)
            switch key {
            case .tick:
                continue
            case .up:
                selectedIndex = max(selectedIndex - 1, 0)
                selectedItemID = feedTUIItem(in: items, at: selectedIndex)?.id
            case .down:
                selectedIndex = min(selectedIndex + 1, max(items.count - 1, 0))
                selectedItemID = feedTUIItem(in: items, at: selectedIndex)?.id
            case .refresh:
                continue
            case .quit:
                return
            case .enter:
                if let item = feedTUIItem(in: items, at: selectedIndex) {
                    statusLine = try resolveFeedTUIItem(
                        item,
                        key: .enter,
                        client: client,
                        rawMode: &rawMode,
                        selectedQuestionOptions: &selectedQuestionOptions
                    )
                }
            case .deny:
                if let item = feedTUIItem(in: items, at: selectedIndex) {
                    statusLine = try resolveFeedTUIItem(
                        item,
                        key: .deny,
                        client: client,
                        rawMode: &rawMode,
                        selectedQuestionOptions: &selectedQuestionOptions
                    )
                }
            case .feedback:
                if let item = feedTUIItem(in: items, at: selectedIndex) {
                    statusLine = try resolveFeedTUIItem(
                        item,
                        key: .feedback,
                        client: client,
                        rawMode: &rawMode,
                        selectedQuestionOptions: &selectedQuestionOptions
                    )
                }
            case .once, .always, .all, .bypass, .manual, .autoAccept, .ultraplan, .number(_):
                if let item = feedTUIItem(in: items, at: selectedIndex) {
                    statusLine = try resolveFeedTUIItem(
                        item,
                        key: key,
                        client: client,
                        rawMode: &rawMode,
                        selectedQuestionOptions: &selectedQuestionOptions
                    )
                }
            case .ignored:
                continue
            }
        }
    }

}
