import Foundation

extension CMUXCLI {
    static var shotHelp: String {
        String(localized: "cli.help.shot", defaultValue: """
        Usage: cmux shot [flags]

        Screenshot a cmux window, or a region of one, to a png or a jpeg. Only
        cmux's own windows can be captured, and no Screen Recording permission
        is involved, so this works on a release build and inside CI.

        Flags:
          --format png|jpg       Output format (default: png)
          --jpg                  Shorthand for --format jpg
          --scale <0.1-1>        Scale the output (default: 1)
          --max-width <64-8192>  Cap the output width, keeping the aspect ratio
          --quality <0.1-1>      JPEG quality (default: 0.8, ignored for png)
          --region <x,y,w,h>     Capture part of the window, in window points
          --out <path>           Write here instead of a temporary directory
          --label <text>         Name the file
          --caption <text>       Draw a caption into the image
          --window <id|ref|index>  Window to capture (default: the frontmost one)

        Output: `<width>x<height> <bytes> <path>`, or the full response with --json.

        A region is the same rectangle `cmux record --region` films, so a
        detail spotted in a clip can be shot with the same four numbers.

        Example:
          cmux shot --label settings-sheet
          cmux shot --region 0,0,420,900 --out ~/sidebar.png
        """)
    }

    static var shotUsageLine: String {
        String(
            localized: "cli.usage.shot",
            defaultValue: "shot [--format png|jpg] [--jpg] [--scale <n>] [--max-width <n>] [--quality <n>] [--region <x,y,w,h>] [--out <path>] [--label <text>] [--caption <text>] [--window <id|ref|index>]"
        )
    }

    func runShotCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        windowOverride: String?
    ) throws {
        let (format, afterFormat) = parseCaptureOption(commandArgs, name: "--format")
        let (scale, afterScale) = parseCaptureOption(afterFormat, name: "--scale")
        let (maxWidth, afterWidth) = parseCaptureOption(afterScale, name: "--max-width")
        let (quality, afterQuality) = parseCaptureOption(afterWidth, name: "--quality")
        let (region, afterRegion) = parseCaptureOption(afterQuality, name: "--region")
        let (out, afterOut) = parseCaptureOption(afterRegion, name: "--out")
        let (label, afterLabel) = parseCaptureOption(afterOut, name: "--label")
        let (caption, afterCaption) = parseCaptureOption(afterLabel, name: "--caption")
        let (window, afterWindow) = parseCaptureOption(afterCaption, name: "--window")

        var trailing = afterWindow
        let wantsJPEG = trailing.contains("--jpg")
        trailing.removeAll { $0 == "--jpg" }
        guard trailing.isEmpty else {
            throw CLIError(message: String(
                format: String(
                    localized: "cli.shot.error.unexpectedArguments",
                    defaultValue: "shot: unexpected arguments: %@"
                ),
                trailing.joined(separator: " ")
            ))
        }

        if wantsJPEG, let format, !["jpg", "jpeg"].contains(format.lowercased()) {
            throw CLIError(message: String(
                localized: "cli.shot.error.formatConflict",
                defaultValue: "shot: --jpg conflicts with --format"
            ))
        }

        // Values stay as the caller typed them: the app owns the limits, so the
        // CLI cannot disagree with it about what a valid width is.
        var params: [String: Any] = [:]
        if let format { params["format"] = format } else if wantsJPEG { params["format"] = "jpg" }
        if let scale { params["scale"] = scale }
        if let maxWidth { params["max_width"] = maxWidth }
        if let quality { params["quality"] = quality }
        if let region { params["region"] = region }
        if let label { params["label"] = label }
        if let caption { params["caption"] = caption }
        if let out { params["out"] = Self.absoluteCapturePath(out) }
        if let windowID = try normalizeWindowHandle(window ?? windowOverride, client: client) {
            params["window"] = windowID
        }

        let response = try client.sendV2(
            method: "window.screenshot",
            params: params,
            responseTimeout: 45
        )
        if jsonOutput {
            print(jsonString(response))
            return
        }
        print(Self.shotLine(response))
    }

    static func shotLine(_ response: [String: Any]) -> String {
        let width = (response["width"] as? Int).map(String.init) ?? "-"
        let height = (response["height"] as? Int).map(String.init) ?? "-"
        let bytes = (response["bytes"] as? Int).map(String.init) ?? "-"
        let path = (response["path"] as? String) ?? "-"
        return "\(width)x\(height) \(bytes) \(path)"
    }
}
