import Foundation

extension CMUXCLI {
    static var recordHelp: String {
        String(localized: "cli.help.record", defaultValue: """
        Usage: cmux record [start] [flags]
               cmux record stop|status [--id <id>]
               cmux record note [--id <id>] <text>
               cmux record list

        Record a cmux window to an mp4 or gif, for a pull request or a bug
        report. Only cmux's own windows can be recorded, and no Screen
        Recording permission is involved.

        Flags for start:
          --format mp4|gif       Output format (default: mp4)
          --gif                  Shorthand for --format gif
          --fps <1-30>           Frames per second (default: 12 for mp4, 8 for gif)
          --max-seconds <n>      Stop by itself after n seconds, 0.5-120 (default: 15)
          --scale <0.1-1>        Scale the output (default: 1 for mp4, 0.5 for gif)
          --max-width <64-4096>  Cap the output width, keeping the aspect ratio
          --region <x,y,w,h>     Record part of the window, in window points
          --out <path>           Write here instead of a temporary directory
          --label <text>         Name the file
          --no-captions          Do not draw `record note` captions into the clip
          --window <id|ref|index>  Window to record (default: the frontmost one)

        Output: `<id> <state> <frames> <path>`, or the full response with --json.

        A recording stops itself at --max-seconds, so a clip is never left
        running by an agent that goes away. One recording at a time.

        Example:
          cmux record start --gif --max-seconds 8 --label sidebar-drag
          cmux record note "dragging the workspace"
          cmux record stop
        """)
    }

    static var recordUsageLine: String {
        String(
            localized: "cli.usage.record",
            defaultValue: "record [start] [--format mp4|gif] [--gif] [--fps <n>] [--max-seconds <n>] [--scale <n>] [--max-width <n>] [--region <x,y,w,h>] [--out <path>] [--label <text>] [--no-captions] [--window <id|ref|index>] | record stop|status [--id <id>] | record note [--id <id>] <text> | record list"
        )
    }

    func runRecordCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        windowOverride: String?
    ) throws {
        // `cmux record --gif` is `cmux record start --gif`: the subcommand is
        // only a subcommand when it is not a flag.
        let hasSubcommand = !(commandArgs.first?.hasPrefix("-") ?? true)
        let subcommand = hasSubcommand ? commandArgs[0].lowercased() : "start"
        let arguments = hasSubcommand ? Array(commandArgs.dropFirst()) : commandArgs

        switch subcommand {
        case "start":
            try runRecordStart(
                arguments: arguments,
                client: client,
                jsonOutput: jsonOutput,
                windowOverride: windowOverride
            )
        case "stop", "status":
            var (recordingID, trailing) = parseCaptureOption(arguments, name: "--id")
            if recordingID == nil, let positional = trailing.first, !positional.hasPrefix("-") {
                recordingID = positional
                trailing = Array(trailing.dropFirst())
            }
            try requireNoRecordArguments(trailing, subcommand: subcommand)
            var params: [String: Any] = [:]
            if let recordingID { params["id"] = recordingID }
            printRecordStatus(
                try client.sendV2(
                    method: subcommand == "stop" ? "window.record.stop" : "window.record.status",
                    params: params,
                    responseTimeout: 60
                ),
                jsonOutput: jsonOutput
            )
        case "note":
            let (id, parsed) = parseCaptureOption(arguments, name: "--id")
            // Only a leading `--` ends the options; one later in the text is
            // part of the caption.
            let trailing = parsed.first == "--" ? Array(parsed.dropFirst()) : parsed
            let text = trailing.joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                throw CLIError(message: String(
                    localized: "cli.record.error.noteText",
                    defaultValue: "record note: text is required"
                ))
            }
            var params: [String: Any] = ["text": text]
            if let id { params["id"] = id }
            printRecordStatus(
                try client.sendV2(method: "window.record.note", params: params),
                jsonOutput: jsonOutput
            )
        case "list":
            try requireNoRecordArguments(arguments, subcommand: subcommand)
            let response = try client.sendV2(method: "window.record.list")
            if jsonOutput {
                print(jsonString(response))
                return
            }
            let recordings = (response["recordings"] as? [[String: Any]]) ?? []
            for recording in recordings {
                print(Self.recordStatusLine(recording))
            }
        default:
            throw CLIError(message: String(
                format: String(
                    localized: "cli.record.error.unknownSubcommand",
                    defaultValue: "record: unknown subcommand '%@' (start, stop, status, note, list)"
                ),
                subcommand
            ))
        }
    }

    private func runRecordStart(
        arguments: [String],
        client: SocketClient,
        jsonOutput: Bool,
        windowOverride: String?
    ) throws {
        let (format, afterFormat) = parseCaptureOption(arguments, name: "--format")
        let (fps, afterFPS) = parseCaptureOption(afterFormat, name: "--fps")
        let (maxSeconds, afterSeconds) = parseCaptureOption(afterFPS, name: "--max-seconds")
        let (scale, afterScale) = parseCaptureOption(afterSeconds, name: "--scale")
        let (maxWidth, afterWidth) = parseCaptureOption(afterScale, name: "--max-width")
        let (region, afterRegion) = parseCaptureOption(afterWidth, name: "--region")
        let (out, afterOut) = parseCaptureOption(afterRegion, name: "--out")
        let (label, afterLabel) = parseCaptureOption(afterOut, name: "--label")
        let (window, afterWindow) = parseCaptureOption(afterLabel, name: "--window")

        var trailing = afterWindow
        let wantsGIF = trailing.contains("--gif")
        let drawsCaptions = !trailing.contains("--no-captions")
        trailing.removeAll { $0 == "--gif" || $0 == "--no-captions" }
        try requireNoRecordArguments(trailing, subcommand: "start")

        if wantsGIF, let format, format.lowercased() != "gif" {
            throw CLIError(message: String(
                localized: "cli.record.error.formatConflict",
                defaultValue: "record start: --gif conflicts with --format"
            ))
        }

        // Values stay as the caller typed them: the app owns the limits, so the
        // CLI cannot disagree with it about what a valid frame rate is.
        var params: [String: Any] = [:]
        if let format { params["format"] = format } else if wantsGIF { params["format"] = "gif" }
        if let fps { params["fps"] = fps }
        if let maxSeconds { params["max_seconds"] = maxSeconds }
        if let scale { params["scale"] = scale }
        if let maxWidth { params["max_width"] = maxWidth }
        if let region { params["region"] = region }
        if let label { params["label"] = label }
        if !drawsCaptions { params["captions"] = false }
        // The app has no idea what directory the CLI was run from.
        if let out { params["out"] = Self.absoluteCapturePath(out) }
        if let windowID = try normalizeWindowHandle(window ?? windowOverride, client: client) {
            params["window"] = windowID
        }

        printRecordStatus(
            try client.sendV2(
                method: "window.record.start",
                params: params,
                responseTimeout: 45
            ),
            jsonOutput: jsonOutput
        )
    }

    /// A flag where a value belongs is a typo rather than a value: plain
    /// `parseOption` would let `--label --gif` name the clip "--gif" and quietly
    /// drop the format. Hand both back so the caller's error names them.
    ///
    /// Shared with `cmux shot`, which has the same flags and the same problem.
    func parseCaptureOption(_ args: [String], name: String) -> (String?, [String]) {
        let (value, remaining) = parseOption(args, name: name)
        guard let value, value.hasPrefix("--") else { return (value, remaining) }
        return (nil, [name, value] + remaining)
    }

    private func requireNoRecordArguments(_ trailing: [String], subcommand: String) throws {
        guard trailing.isEmpty else {
            throw CLIError(message: String(
                format: String(
                    localized: "cli.record.error.unexpectedArguments",
                    defaultValue: "record %@: unexpected arguments: %@"
                ),
                subcommand,
                trailing.joined(separator: " ")
            ))
        }
    }

    private func printRecordStatus(_ response: [String: Any], jsonOutput: Bool) {
        if jsonOutput {
            print(jsonString(response))
            return
        }
        print(Self.recordStatusLine(response))
    }

    static func recordStatusLine(_ response: [String: Any]) -> String {
        let id = (response["id"] as? String) ?? "-"
        let state = (response["state"] as? String) ?? "-"
        let frames = (response["frames"] as? Int).map(String.init) ?? "-"
        let path = (response["path"] as? String) ?? "-"
        var line = "\(id) \(state) \(frames) \(path)"
        if let error = response["error"] as? String, !error.isEmpty {
            line += " (\(error))"
        }
        return line
    }

    /// The app has no idea what directory the CLI was run from, so `--out`
    /// becomes absolute here. Shared with `cmux shot`.
    static func absoluteCapturePath(_ path: String) -> String {
        let expanded = NSString(string: path).expandingTildeInPath
        guard !expanded.hasPrefix("/") else { return expanded }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(expanded)
            .standardizedFileURL
            .path
    }
}
