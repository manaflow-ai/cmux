import Darwin
import Foundation

extension CMUXCLI {
    func iosRunUsageSummaryLine() -> String {
        String(
            localized: "cli.ios.usageSummary",
            defaultValue: "ios run [--app <path> | --xcode-workspace <path> --scheme <name>] [--device <name|udid>] [--no-open] (build, run, and stream an iOS Simulator app in a browser pane)"
        )
    }

    func iosUsageText() -> String {
        String(
            localized: "cli.ios.usage",
            defaultValue: """
            Usage: cmux ios run [options]

            Build or install an iOS Simulator app, launch it, start a local simulator
            stream, and open that stream in a cmux browser pane. The pane forwards
            taps, scrolls, and keyboard input to the simulator when an input bridge
            is available.

            Options:
              --app <path>                 Install and launch an already-built .app
              --bundle-id <id>             Bundle identifier to launch (auto-detected from --app when omitted)
              --xcode-workspace <path>     Build from an .xcworkspace
              --xcode-project <path>       Build from an .xcodeproj
              --scheme <name>              Xcode scheme (auto-detected when only one scheme is available)
              --configuration <name>       Xcode configuration (default: Debug)
              --derived-data <path>        DerivedData path for the build
              --device <name|udid>         Simulator device (default: a booted iPhone simulator, then first available iPhone)
              --port <n>                   Local server port (default: 0, choose an available port)
              --cwd <path>                 Project working directory (default: current directory)
              --input-command <argv>       External input bridge command; receives event JSON on stdin
              --workspace <id|ref|index>   Target cmux workspace for the browser pane
              --window <id|ref|index>      Target cmux window for the browser pane
              --focus <true|false>         Focus the browser pane after opening (default: false)
              --no-build                   Skip xcodebuild and use --app
              --no-open                    Start the stream server but do not open a browser pane
              --json                       Print machine-readable output

            Environment:
              CMUX_IOS_INPUT_COMMAND       Fallback input bridge command when --input-command is omitted

            Notes:
              SwiftUI previews and hot reload are planned follow-up slices. This command
              delivers the build/install/launch/browser-stream loop for the running app.
            """
        )
    }

    func runIOSCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let subcommand = commandArgs.first?.lowercased()
        switch subcommand {
        case nil, "help":
            print(iosUsageText())
        case "run":
            try runIOSRunCommand(
                commandArgs: Array(commandArgs.dropFirst()),
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat
            )
        default:
            let format = String(
                localized: "cli.ios.error.unknownSubcommand",
                defaultValue: "Unknown ios subcommand: %@. Usage: cmux ios run [options]"
            )
            throw CLIError(message: String(format: format, subcommand ?? ""))
        }
    }

    private func runIOSRunCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        var appPath: String?
        var bundleID: String?
        var xcodeWorkspace: String?
        var xcodeProject: String?
        var scheme: String?
        var configuration: String?
        var derivedData: String?
        var device: String?
        var port: String?
        var cwd: String?
        var inputCommand: String?
        var cmuxWorkspace: String?
        var cmuxWindow: String?
        var focus: String?
        var noOpen = false
        var noBuild = false

        let valueOptions: Set<String> = [
            "--app",
            "--bundle-id",
            "--xcode-workspace",
            "--xcode-project",
            "--scheme",
            "--configuration",
            "--derived-data",
            "--device",
            "--port",
            "--cwd",
            "--input-command",
            "--workspace",
            "--window",
            "--focus",
        ]
        let flagOptions: Set<String> = ["--no-open", "--no-build"]

        var index = 0
        while index < commandArgs.count {
            let arg = commandArgs[index]
            if arg == "--" {
                let format = String(
                    localized: "cli.ios.error.unexpectedArgument",
                    defaultValue: "ios run: unexpected argument '%@'"
                )
                let extra = Array(commandArgs.dropFirst(index + 1)).joined(separator: " ")
                throw CLIError(message: String(format: format, extra))
            }
            if flagOptions.contains(arg) {
                if arg == "--no-open" {
                    noOpen = true
                } else if arg == "--no-build" {
                    noBuild = true
                }
                index += 1
                continue
            }

            let name: String
            let value: String
            if let equals = arg.firstIndex(of: "="), arg.hasPrefix("--") {
                name = String(arg[..<equals])
                value = String(arg[arg.index(after: equals)...])
            } else {
                name = arg
                guard valueOptions.contains(name) else {
                    let format = String(
                        localized: "cli.ios.error.unknownFlag",
                        defaultValue: "ios run: unknown flag or argument '%@'"
                    )
                    throw CLIError(message: String(format: format, arg))
                }
                guard index + 1 < commandArgs.count, !commandArgs[index + 1].hasPrefix("--") else {
                    let format = String(
                        localized: "cli.ios.error.optionRequiresValue",
                        defaultValue: "ios run: %@ requires a value"
                    )
                    throw CLIError(message: String(format: format, name))
                }
                value = commandArgs[index + 1]
                index += 1
            }

            guard valueOptions.contains(name) else {
                let format = String(
                    localized: "cli.ios.error.unknownFlag",
                    defaultValue: "ios run: unknown flag or argument '%@'"
                )
                throw CLIError(message: String(format: format, name))
            }

            switch name {
            case "--app": appPath = value
            case "--bundle-id": bundleID = value
            case "--xcode-workspace": xcodeWorkspace = value
            case "--xcode-project": xcodeProject = value
            case "--scheme": scheme = value
            case "--configuration": configuration = value
            case "--derived-data": derivedData = value
            case "--device": device = value
            case "--port": port = value
            case "--cwd": cwd = resolvePath(value)
            case "--input-command": inputCommand = value
            case "--workspace": cmuxWorkspace = value
            case "--window": cmuxWindow = value
            case "--focus": focus = value
            default: break
            }
            index += 1
        }

        if let port, Int(port) == nil {
            throw CLIError(message: String(localized: "cli.ios.error.invalidPort", defaultValue: "ios run: --port must be an integer"))
        }
        if noBuild && appPath == nil {
            throw CLIError(message: String(localized: "cli.ios.error.noBuildRequiresApp", defaultValue: "ios run: --no-build requires --app"))
        }

        let scriptURL = try iosSimulatorServerScriptURL()
        let logURL = try iosLoopLogURL()
        let ready = try launchIOSSimulatorServer(
            scriptURL: scriptURL,
            logURL: logURL,
            appPath: appPath,
            bundleID: bundleID,
            xcodeWorkspace: xcodeWorkspace,
            xcodeProject: xcodeProject,
            scheme: scheme,
            configuration: configuration,
            derivedData: derivedData,
            device: device,
            port: port,
            cwd: cwd,
            inputCommand: inputCommand,
            noBuild: noBuild
        )

        guard let url = ready.payload["url"] as? String,
              !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            ready.process.terminate()
            throw CLIError(message: String(localized: "cli.ios.error.invalidReadyPayload", defaultValue: "ios simulator server returned an invalid ready payload"))
        }

        var outputPayload = ready.payload
        outputPayload["pid"] = Int(ready.process.processIdentifier)
        outputPayload["log_path"] = logURL.path
        outputPayload["opened_browser"] = false

        if !noOpen {
            do {
                var params: [String: Any] = ["url": url]
                let windowHandle = try cmuxWindow.flatMap { try normalizeWindowHandle($0, client: client) }
                if let windowHandle {
                    params["window_id"] = windowHandle
                }
                let workspaceRaw = cmuxWorkspace ?? (cmuxWindow == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
                if let workspaceHandle = try workspaceRaw.flatMap({
                    try normalizeWorkspaceHandle($0, client: client, windowHandle: windowHandle)
                }) {
                    params["workspace_id"] = workspaceHandle
                }
                try applyFocusOption(focus, defaultValue: false, to: &params)
                let browserPayload = try client.sendV2(method: "browser.open_split", params: params)
                outputPayload["opened_browser"] = true
                outputPayload["browser"] = browserPayload
            } catch {
                ready.process.terminate()
                throw error
            }
        }

        if jsonOutput {
            print(jsonString(formatIDs(outputPayload, mode: idFormat)))
            return
        }

        let ok = String(localized: "common.ok", defaultValue: "OK")
        var parts = ["\(ok) url=\(url)", "pid=\(ready.process.processIdentifier)", "log=\(logURL.path)"]
        if let browserPayload = outputPayload["browser"] as? [String: Any] {
            if let surface = formatHandle(browserPayload, kind: "surface", idFormat: idFormat) {
                parts.append("surface=\(surface)")
            }
            if let pane = formatHandle(browserPayload, kind: "pane", idFormat: idFormat) {
                parts.append("pane=\(pane)")
            }
        }
        print(parts.joined(separator: " "))
    }

    private func iosSimulatorServerScriptURL() throws -> URL {
        let fileManager = FileManager.default
        var candidates: [URL] = []
        var seen: Set<String> = []

        func append(_ url: URL?) {
            guard let url else { return }
            let standardized = url.standardizedFileURL
            guard seen.insert(standardized.path).inserted else { return }
            candidates.append(standardized)
        }

        append(CLIExecutableLocator.enclosingAppBundle()?.resourceURL?.appendingPathComponent("bin/cmux-ios-sim-server.py", isDirectory: false))
        append(Bundle.main.resourceURL?.appendingPathComponent("bin/cmux-ios-sim-server.py", isDirectory: false))

        if let executableURL = resolvedExecutableURL() {
            var current = executableURL.deletingLastPathComponent().standardizedFileURL
            while true {
                append(current.appendingPathComponent("Resources/bin/cmux-ios-sim-server.py", isDirectory: false))
                append(current.appendingPathComponent("Contents/Resources/bin/cmux-ios-sim-server.py", isDirectory: false))
                guard let parent = CLIExecutableLocator.parentSearchURL(for: current) else {
                    break
                }
                current = parent
            }
        }

        append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("Resources/bin/cmux-ios-sim-server.py", isDirectory: false))

        for candidate in candidates where fileManager.fileExists(atPath: candidate.path) {
            return candidate
        }

        throw CLIError(message: String(localized: "cli.ios.error.helperMissing", defaultValue: "cmux iOS simulator server helper was not found in the app bundle or source checkout"))
    }

    private func iosLoopLogURL() throws -> URL {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/cmux/ios-dev-loop", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        return base.appendingPathComponent("\(timestamp)-\(UUID().uuidString.prefix(8)).log", isDirectory: false)
    }

    private func launchIOSSimulatorServer(
        scriptURL: URL,
        logURL: URL,
        appPath: String?,
        bundleID: String?,
        xcodeWorkspace: String?,
        xcodeProject: String?,
        scheme: String?,
        configuration: String?,
        derivedData: String?,
        device: String?,
        port: String?,
        cwd: String?,
        inputCommand: String?,
        noBuild: Bool
    ) throws -> (process: Process, payload: [String: Any]) {
        let pythonPath = "/usr/bin/python3"
        guard FileManager.default.isExecutableFile(atPath: pythonPath) else {
            throw CLIError(message: String(localized: "cli.ios.error.pythonMissing", defaultValue: "/usr/bin/python3 is required to run the cmux iOS simulator server"))
        }

        var arguments = [scriptURL.path, "serve", "--host", "127.0.0.1", "--port", port ?? "0"]
        arguments.append(contentsOf: ["--cwd", cwd ?? FileManager.default.currentDirectoryPath])
        if let appPath { arguments.append(contentsOf: ["--app", appPath]) }
        if let bundleID { arguments.append(contentsOf: ["--bundle-id", bundleID]) }
        if let xcodeWorkspace { arguments.append(contentsOf: ["--xcode-workspace", xcodeWorkspace]) }
        if let xcodeProject { arguments.append(contentsOf: ["--xcode-project", xcodeProject]) }
        if let scheme { arguments.append(contentsOf: ["--scheme", scheme]) }
        if let configuration { arguments.append(contentsOf: ["--configuration", configuration]) }
        if let derivedData { arguments.append(contentsOf: ["--derived-data", derivedData]) }
        if let device { arguments.append(contentsOf: ["--device", device]) }
        if let inputCommand { arguments.append(contentsOf: ["--input-command", inputCommand]) }
        if noBuild { arguments.append("--no-build") }

        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        guard let logHandle = FileHandle(forWritingAtPath: logURL.path) else {
            throw CLIError(message: String(localized: "cli.ios.error.logOpenFailed", defaultValue: "Unable to create the iOS simulator server log file"))
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        process.environment = environment

        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = logHandle

        do {
            try process.run()
        } catch {
            try? logHandle.close()
            throw CLIError(message: String(describing: error))
        }
        try? logHandle.close()

        let readyTimeoutSeconds: TimeInterval = 30 * 60
        let readyRead = readLineData(from: stdoutPipe.fileHandleForReading, timeout: readyTimeoutSeconds)
        if readyRead.timedOut {
            process.terminate()
            let format = String(
                localized: "cli.ios.error.readyTimeout",
                defaultValue: "iOS simulator server did not become ready within %.0f seconds. See log: %@"
            )
            throw CLIError(message: String(format: format, readyTimeoutSeconds, logURL.path))
        }
        let readyData = readyRead.data
        guard !readyData.isEmpty else {
            let format = String(
                localized: "cli.ios.error.helperExited",
                defaultValue: "iOS simulator server exited before it became ready. See log: %@"
            )
            throw CLIError(message: String(format: format, logURL.path))
        }

        let decoded: Any
        do {
            decoded = try JSONSerialization.jsonObject(with: readyData)
        } catch {
            process.terminate()
            let format = String(
                localized: "cli.ios.error.readyDecodeFailed",
                defaultValue: "iOS simulator server returned unreadable ready data. See log: %@"
            )
            throw CLIError(message: String(format: format, logURL.path))
        }

        guard let payload = decoded as? [String: Any] else {
            process.terminate()
            throw CLIError(message: String(localized: "cli.ios.error.invalidReadyPayload", defaultValue: "ios simulator server returned an invalid ready payload"))
        }
        return (process, payload)
    }

    private func readLineData(from handle: FileHandle, timeout: TimeInterval) -> (data: Data, timedOut: Bool) {
        let maxReadyBytes = 1_048_576
        let chunkSize = 4096
        let deadline = Date().addingTimeInterval(timeout)
        let fileDescriptor = handle.fileDescriptor
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        var data = Data()
        while data.count < maxReadyBytes {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 {
                return (data, true)
            }

            var pollInfo = pollfd(fd: fileDescriptor, events: Int16(POLLIN), revents: 0)
            let timeoutMilliseconds = Int32(min(remaining * 1000, Double(Int32.max)))
            let pollResult = Darwin.poll(&pollInfo, 1, timeoutMilliseconds)
            if pollResult == 0 {
                return (data, true)
            }
            if pollResult < 0 {
                if errno == EINTR {
                    continue
                }
                break
            }

            if (pollInfo.revents & Int16(POLLIN)) == 0 {
                break
            }

            let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(fileDescriptor, rawBuffer.baseAddress, chunkSize)
            }
            if bytesRead == 0 {
                break
            }
            if bytesRead < 0 {
                if errno == EINTR {
                    continue
                }
                break
            }

            let readable = buffer.prefix(Int(bytesRead))
            if let newlineIndex = readable.firstIndex(of: 10) {
                data.append(contentsOf: readable[..<newlineIndex])
                return (data, false)
            }
            data.append(contentsOf: readable)
        }
        return (data, false)
    }
}
