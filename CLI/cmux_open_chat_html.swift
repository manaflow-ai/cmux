import Foundation

extension CMUXCLI {
    struct OpenChatWriteResult {
        var fileURL: URL
        var url: URL
        var title: String
        var allowedFiles: [DiffViewerAllowedFile]
    }

    func writeOpenChat(
        context: OpenChatContext,
        appearance: DiffViewerAppearance,
        runtime: URL?
    ) throws -> OpenChatWriteResult {
        let directory = try diffViewerDirectory()
        let origin = try diffViewerHTTPServerOrigin(rootDirectory: directory, runtime: runtime)
        let mapper = DiffViewerURLMapper(
            token: UUID().uuidString.lowercased(),
            rootDirectory: directory,
            origin: origin,
            sessionHistoryMarker: DiffViewerURLMapper.openChatSessionHistoryMarker
        )
        let timestamp = Int(Date().timeIntervalSince1970)
        let filename = "chat-\(timestamp)-\(UUID().uuidString.prefix(8)).html"
        let viewerFileURL = directory.appendingPathComponent(filename, isDirectory: false)
        let title = OpenChatLabels.localized().values["title"] ?? "Open Chat"
        let assets = try ensureDiffViewerAssets(nextTo: viewerFileURL, runtime: runtime)
        try writeOpenChatHTML(
            to: viewerFileURL,
            title: title,
            context: context,
            appearance: appearance,
            assets: assets
        )
        let allowedFiles = try diffViewerAllowedFiles(
            pageURLs: [viewerFileURL],
            assets: assets,
            mapper: mapper
        )
        try writeDiffViewerHTTPManifest(
            token: mapper.token,
            files: allowedFiles,
            rootDirectory: directory
        )
        return OpenChatWriteResult(
            fileURL: viewerFileURL,
            url: try mapper.viewerURL(for: viewerFileURL),
            title: title,
            allowedFiles: allowedFiles
        )
    }

    private func writeOpenChatHTML(
        to viewerURL: URL,
        title: String,
        context: OpenChatContext,
        appearance: DiffViewerAppearance,
        assets: DiffViewerAssets
    ) throws {
        let labels = OpenChatLabels.localized()
        var payload: [String: Any] = [
            "title": title,
            "workspaceName": context.workspaceName,
            "repoName": context.repoName,
            "branchName": context.branchLabel,
            "appearance": appearance.jsonObject,
            "labels": labels.jsonObject,
            "rateLimit": [
                "resetTime": openChatPlaceholderResetTime()
            ],
            "models": [
                ["id": "5.5", "label": "5.5", "selected": true],
                ["id": "5.1", "label": "5.1", "selected": false],
                ["id": "5", "label": "5", "selected": false],
            ],
            "reasoningLevels": [
                ["id": "extra-high", "label": labels.values["reasoningExtraHigh"] ?? "Extra High", "selected": true],
                ["id": "high", "label": labels.values["reasoningHigh"] ?? "High", "selected": false],
                ["id": "medium", "label": labels.values["reasoningMedium"] ?? "Medium", "selected": false],
                ["id": "low", "label": labels.values["reasoningLow"] ?? "Low", "selected": false],
            ],
            "approvalModes": [
                ["id": "full-access", "label": labels.values["approvalFullAccess"] ?? "Full access", "selected": true, "warning": true],
                ["id": "auto-review", "label": labels.values["approvalAutoReview"] ?? "Auto-review", "selected": false, "warning": false],
                ["id": "read-only", "label": labels.values["approvalReadOnly"] ?? "Read only", "selected": false, "warning": false],
                ["id": "default", "label": labels.values["approvalDefault"] ?? "Default", "selected": false, "warning": false],
            ],
            "contextOptions": [
                "repositories": [
                    ["id": context.repoName, "label": context.repoName, "selected": true],
                ],
                "environments": [
                    ["id": "local", "label": labels.values["workLocally"] ?? "Work locally", "selected": true],
                ],
                "branches": [
                    ["id": context.branchName ?? "no-branch", "label": context.branchLabel, "selected": true],
                ],
            ],
            "suggestions": [
                ["id": "example", "kind": "prompt", "label": labels.values["exampleSuggestion"] ?? "Plan and build a polished feature from this workspace"],
                ["id": "apps", "kind": "apps", "label": labels.values["connectApps"] ?? "Connect your favorite apps to Codex"],
            ],
            "generatedAt": ISO8601DateFormatter().string(from: Date())
        ]
        if let repoRoot = context.repoRoot {
            payload["repoRoot"] = repoRoot
        }
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
        let prepaintStyle = diffViewerPrepaintStyle(appearance: appearance)
        let html = """
        <!doctype html>
        <html lang="\(htmlEscaped(htmlLanguage))" data-cmux-webview-kind="open-chat">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>\(escapedTitle)</title>
          \(prepaintStyle)
        </head>
        <body data-cmux-webview-kind="open-chat">
          <script id="cmux-open-chat-config" type="application/json">\(configLiteral)</script>
          <div id="root"></div>
          <script type="module" src="\(appModuleURL)"></script>
        </body>
        </html>
        """
        try html.write(to: viewerURL, atomically: true, encoding: .utf8)
    }

    private func openChatPlaceholderResetTime() -> String {
        let resetDate = Date().addingTimeInterval(2 * 60 * 60)
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        formatter.locale = Locale.current
        return formatter.string(from: resetDate)
    }
}
