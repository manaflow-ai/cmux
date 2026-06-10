import Darwin
import Foundation


// MARK: - Diff Viewer Page Writing
extension CMUXCLI {
    func writeDiffViewer(
        rawInput: String?,
        source: DiffSource?,
        titleOverride: String?,
        layout: String,
        layoutSource: String,
        appearance: DiffViewerAppearance,
        context: DiffSourceContext,
        runtime: URL?
    ) throws -> DiffViewerWriteResult {
        if let source {
            return try writeGitDiffViewerHTMLSet(
                selectedSource: source,
                titleOverride: titleOverride,
                layout: layout,
                layoutSource: layoutSource,
                appearance: appearance,
                context: context,
                runtime: runtime
            )
        }

        let input = try readDiffInput(rawInput, source: nil, context: context)
        if input.remotePatchURL == nil {
            let trimmedPatch = input.patch.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedPatch.isEmpty else {
                throw CLIError(message: input.emptyMessage ?? "diff input is empty")
            }
        }

        let title = titleOverride ?? input.defaultTitle
        let directory = try diffViewerDirectory()
        let origin = try diffViewerHTTPServerOrigin(rootDirectory: directory, runtime: runtime)
        let mapper = DiffViewerURLMapper(
            token: UUID().uuidString.lowercased(),
            rootDirectory: directory,
            origin: origin
        )
        let timestamp = Int(Date().timeIntervalSince1970)
        let filename = "diff-\(timestamp)-\(UUID().uuidString.prefix(8)).html"
        let viewerFileURL = directory.appendingPathComponent(filename, isDirectory: false)
        try writeDiffViewerHTML(
            to: viewerFileURL,
            patch: input.patch,
            title: title,
            sourceLabel: input.sourceLabel,
            externalURL: input.externalURL,
            remotePatchURL: input.remotePatchURL,
            layout: layout,
            layoutSource: layoutSource,
            appearance: appearance,
            sourceOptions: [],
            runtime: runtime
        )
        let assets = try ensureDiffViewerAssets(nextTo: viewerFileURL, runtime: runtime)
        let allowedFiles = try diffViewerAllowedFiles(
            pageURLs: [viewerFileURL],
            assets: assets,
            mapper: mapper,
            remotePatchURLsByPagePath: remotePatchURLMap(pageURL: viewerFileURL, remoteURL: input.remotePatchURL)
        )
        try writeDiffViewerHTTPManifest(
            token: mapper.token,
            files: allowedFiles,
            rootDirectory: directory
        )
        return DiffViewerWriteResult(
            fileURL: viewerFileURL,
            url: try mapper.viewerURL(for: viewerFileURL),
            title: title,
            input: input,
            allowedFiles: allowedFiles
        )
    }

    func diffViewerPatchFileURL(for viewerURL: URL) -> URL {
        viewerURL.deletingPathExtension().appendingPathExtension("patch")
    }

    private func diffViewerPatchURLString(for viewerURL: URL) -> String {
        "./\(viewerURL.deletingPathExtension().lastPathComponent).patch"
    }

    private func writeDiffViewerPatchSidecar(_ patch: String, for viewerURL: URL) throws {
        try patch.write(to: diffViewerPatchFileURL(for: viewerURL), atomically: true, encoding: .utf8)
    }

    func writeDiffViewerHTML(
        patch: String,
        title: String,
        sourceLabel: String,
        externalURL: String?,
        remotePatchURL: URL? = nil,
        layout: String,
        layoutSource: String,
        appearance: DiffViewerAppearance,
        sourceOptions: [DiffViewerSourceOption],
        repoOptions: [DiffViewerSourceOption] = [],
        baseOptions: [DiffViewerSourceOption] = [],
        repoRoot: String? = nil,
        branchBaseRef: String? = nil
    ) throws -> URL {
        let directory = try diffViewerDirectory()

        let timestamp = Int(Date().timeIntervalSince1970)
        let filename = "diff-\(timestamp)-\(UUID().uuidString.prefix(8)).html"
        let viewerURL = directory.appendingPathComponent(filename, isDirectory: false)
        try writeDiffViewerHTML(
            to: viewerURL,
            patch: patch,
            title: title,
            sourceLabel: sourceLabel,
            externalURL: externalURL,
            remotePatchURL: remotePatchURL,
            layout: layout,
            layoutSource: layoutSource,
            appearance: appearance,
            sourceOptions: sourceOptions,
            repoOptions: repoOptions,
            baseOptions: baseOptions,
            repoRoot: repoRoot,
            branchBaseRef: branchBaseRef
        )
        return viewerURL
    }

    func writeDiffViewerStatusHTML(
        to viewerURL: URL,
        title: String,
        sourceLabel: String,
        message: String,
        isError: Bool,
        pollForReplacement: Bool,
        layout: String,
        layoutSource: String,
        appearance: DiffViewerAppearance,
        sourceOptions: [DiffViewerSourceOption],
        repoOptions: [DiffViewerSourceOption] = [],
        baseOptions: [DiffViewerSourceOption] = [],
        repoRoot: String? = nil,
        branchBaseRef: String? = nil,
        runtime: URL? = nil
    ) throws {
        try writeDiffViewerHTML(
            to: viewerURL,
            patch: "",
            title: title,
            sourceLabel: sourceLabel,
            externalURL: nil,
            layout: layout,
            layoutSource: layoutSource,
            appearance: appearance,
            sourceOptions: sourceOptions,
            repoOptions: repoOptions,
            baseOptions: baseOptions,
            repoRoot: repoRoot,
            branchBaseRef: branchBaseRef,
            statusMessage: message,
            statusIsError: isError,
            pollForReplacement: pollForReplacement,
            runtime: runtime
        )
    }

    func writeDiffViewerRedirectHTML(
        to viewerURL: URL,
        title: String,
        targetURL: URL,
        appearance: DiffViewerAppearance,
        runtime: URL? = nil
    ) throws {
        try writeDiffViewerPatchSidecar("", for: viewerURL)
        _ = try ensureDiffViewerAssets(nextTo: viewerURL, runtime: runtime)
        let target = targetURL.absoluteString
        let targetLiteral = try jsonStringLiteral(target)
        let escapedTitle = htmlEscaped(title)
        let escapedTarget = htmlEscaped(target)
        let prepaintStyle = diffViewerPrepaintStyle(appearance: appearance)
        let html = """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <meta http-equiv="refresh" content="0;url=\(escapedTarget)">
          <title>\(escapedTitle)</title>
          \(prepaintStyle)
        </head>
        <body data-cmux-diff-redirect="\(escapedTarget)">
          <script>
            window.location.replace(\(targetLiteral));
          </script>
        </body>
        </html>
        """
        try html.write(to: viewerURL, atomically: true, encoding: .utf8)
    }

    func writeDiffViewerHTML(
        to viewerURL: URL,
        patch: String,
        title: String,
        sourceLabel: String,
        externalURL: String?,
        remotePatchURL: URL? = nil,
        layout: String,
        layoutSource: String,
        appearance: DiffViewerAppearance,
        sourceOptions: [DiffViewerSourceOption],
        repoOptions: [DiffViewerSourceOption] = [],
        baseOptions: [DiffViewerSourceOption] = [],
        repoRoot: String? = nil,
        branchBaseRef: String? = nil,
        statusMessage: String? = nil,
        statusIsError: Bool = false,
        pollForReplacement: Bool = false,
        runtime: URL? = nil
    ) throws {
        if remotePatchURL == nil {
            try writeDiffViewerPatchSidecar(patch, for: viewerURL)
        }
        let labels = DiffViewerLabels.localized()
        var payload: [String: Any] = [
            "patchURL": diffViewerPatchURLString(for: viewerURL),
            "title": title,
            "sourceLabel": sourceLabel,
            "layout": layout,
            "layoutSource": layoutSource,
            "appearance": appearance.jsonObject,
            "labels": labels.jsonObject,
            "shortcuts": diffViewerShortcutPayload(),
            "sourceOptions": sourceOptions.map(\.jsonObject),
            "repoOptions": repoOptions.map(\.jsonObject),
            "baseOptions": baseOptions.map(\.jsonObject),
            "generatedAt": ISO8601DateFormatter().string(from: Date())
        ]
        if let statusMessage {
            payload["statusMessage"] = statusMessage
            payload["statusIsError"] = statusIsError
        }
        if pollForReplacement {
            payload["pendingReplacement"] = true
        }
        if let externalURL {
            payload["externalURL"] = externalURL
        }
        if let repoRoot {
            payload["repoRoot"] = repoRoot
        }
        if let branchBaseRef {
            payload["branchBaseRef"] = branchBaseRef
        }
        let assets = try ensureDiffViewerAssets(nextTo: viewerURL, runtime: runtime)
        let config: [String: Any] = [
            "payload": payload,
            "assets": [
                "diffsModuleURL": assets.diffsModuleURL,
                "treesModuleURL": assets.treesModuleURL,
                "workerPoolModuleURL": assets.workerPoolModuleURL,
                "workerModuleURL": assets.workerModuleURL
            ]
        ]
        let configLiteral = try jsonScriptLiteral(config)
        let appModuleURL = htmlEscaped(assets.appModuleURL)
        let escapedTitle = htmlEscaped(title)
        let htmlLanguage = Locale.current.language.languageCode?.identifier ?? "en"
        let pendingAttribute = pollForReplacement ? " data-cmux-diff-pending=\"true\"" : ""
        let prepaintStyle = diffViewerPrepaintStyle(appearance: appearance)
        let html = """
        <!doctype html>
        <html lang="\(htmlEscaped(htmlLanguage))"\(pendingAttribute)>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>\(escapedTitle)</title>
          \(prepaintStyle)
        </head>
        <body>
          <script id="cmux-diff-viewer-config" type="application/json">\(configLiteral)</script>
          <div id="root"></div>
          <script type="module" src="\(appModuleURL)"></script>
        </body>
        </html>
        """
        try html.write(to: viewerURL, atomically: true, encoding: .utf8)
    }

    private func diffViewerPrepaintStyle(appearance: DiffViewerAppearance) -> String {
        let lightBackground = diffViewerCSSColor(
            appearance.lightTheme.background,
            opacity: appearance.backgroundOpacity
        )
        let darkBackground = diffViewerCSSColor(
            appearance.darkTheme.background,
            opacity: appearance.backgroundOpacity
        )
        let lightForeground = diffViewerCSSColor(appearance.lightTheme.foreground)
        let darkForeground = diffViewerCSSColor(appearance.darkTheme.foreground)
        return """
        <style id="cmux-diff-viewer-prepaint">
          :root {
            color-scheme: light dark;
            background: \(lightBackground);
          }
          html,
          body,
          #root {
            min-height: 100%;
          }
          html,
          body {
            margin: 0;
            background: \(lightBackground);
            color: \(lightForeground);
          }
          @media (prefers-color-scheme: dark) {
            :root {
              background: \(darkBackground);
            }
            html,
            body {
              background: \(darkBackground);
              color: \(darkForeground);
            }
          }
        </style>
        """
    }

    private func diffViewerCSSColor(_ rawValue: String, opacity: Double = 1) -> String {
        guard let color = normalizedDiffViewerHexColor(rawValue) else {
            return rawValue
        }
        let clampedOpacity = min(1, max(0, opacity))
        guard clampedOpacity < 1,
              let rgb = diffViewerRGBColor(color) else {
            return color
        }
        let red = Int((rgb.red * 255).rounded())
        let green = Int((rgb.green * 255).rounded())
        let blue = Int((rgb.blue * 255).rounded())
        return "rgba(\(red), \(green), \(blue), \(diffViewerCSSNumber(clampedOpacity)))"
    }

    private func diffViewerCSSNumber(_ value: Double) -> String {
        let rounded = roundedDiffViewerMetric(value)
        if rounded.rounded(.towardZero) == rounded {
            return String(Int(rounded))
        }
        var text = String(rounded)
        while text.hasSuffix("0") {
            text.removeLast()
        }
        if text.hasSuffix(".") {
            text.removeLast()
        }
        return text
    }

    private func jsonScriptLiteral(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
        guard let text = String(data: data, encoding: .utf8) else {
            throw CLIError(message: "Failed to encode diff viewer payload")
        }
        return text.replacingOccurrences(of: "</", with: "<\\/")
    }

    private func jsonStringLiteral(_ value: String) throws -> String {
        let data = try JSONEncoder().encode(value)
        guard let text = String(data: data, encoding: .utf8) else {
            throw CLIError(message: "Failed to encode diff viewer string")
        }
        return text.replacingOccurrences(of: "</", with: "<\\/")
    }

    func htmlEscaped(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

}
