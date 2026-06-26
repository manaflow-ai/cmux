#if DEBUG
import AppKit
import CmuxSettings
import CmuxTestSupport
import Foundation
import GhosttyKit

/// Records the terminal cmd-click UI-test state for the
/// `CMUX_UI_TEST_TERMINAL_CMD_CLICK_*` XCUITest scenario.
///
/// This is the app-target conformer of ``UITestRecording`` for the terminal
/// cmd-click scenario. It owns the live `AppDelegate` it reads
/// workspace / terminal-panel / window state from, seeds the shell fixture
/// through, and drives the cmd-click / hover / selection simulations on the
/// terminal hosted view via the `debugSimulate*` APIs, which is why it cannot
/// live in `CmuxTestSupport` (a lower package cannot reference `AppDelegate`/
/// `TabManager`/`Workspace`/`TerminalPanel`/`TerminalController`).
/// ``installIfNeeded()`` is gated by `CMUX_UI_TEST_TERMINAL_CMD_CLICK_SETUP`
/// and is a no-op in production; it carries its own one-shot guard so the
/// composition root can call it unconditionally during launch.
///
/// On install the recorder builds a fixture directory + escaped/raw/osc8 shell
/// block per the scenario environment, waits for a visible terminal surface,
/// seeds the shell, computes the cmd-click token grid geometry, and (when a
/// command file is configured) executes hover / click / selection / capture
/// commands against the live surface, writing every result to the capture
/// file. The capture file path, JSON shape, and key set (a `[String: Any]`
/// object merged and re-serialized with **sorted** keys) are byte-identical to
/// the legacy `AppDelegate` implementation this was lifted from.
@MainActor
final class TerminalCmdClickUITestRecorder: UITestRecording {
    private unowned let appDelegate: AppDelegate
    private let environment: [String: String]
    private var didSetup = false
    private var poller: DispatchSourceTimer?

    /// Creates a recorder bound to `appDelegate`, reading scenario gates from
    /// `environment`.
    ///
    /// - Parameters:
    ///   - appDelegate: The live app delegate whose workspaces / terminal
    ///     panels the recorder drives.
    ///   - environment: The process environment; defaults to the real one.
    init(
        appDelegate: AppDelegate,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.appDelegate = appDelegate
        self.environment = environment
    }

    deinit {
        poller?.cancel()
    }

    func installIfNeeded() {
        guard !didSetup else { return }

        let env = environment
        guard env["CMUX_UI_TEST_TERMINAL_CMD_CLICK_SETUP"] == "1" else {
            cmuxDebugLog("cmdclick.ui.setup skip reason=env_missing tag=\(env["CMUX_TAG"] ?? "nil")")
            return
        }
        guard let manifestPath = env["CMUX_UI_TEST_TERMINAL_CMD_CLICK_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !manifestPath.isEmpty else {
            cmuxDebugLog("cmdclick.ui.setup skip reason=missing_manifest_path")
            return
        }
        didSetup = true
        guard let fixtureDirectory = env["CMUX_UI_TEST_TERMINAL_CMD_CLICK_FIXTURE_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !fixtureDirectory.isEmpty else {
            cmuxDebugLog("cmdclick.ui.setup error reason=missing_fixture_dir manifest=\(manifestPath)")
            writeData(at: manifestPath, updates: [
                "setupError": "Missing fixture directory"
            ])
            return
        }
        let commandPath = env["CMUX_UI_TEST_TERMINAL_CMD_CLICK_COMMAND_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let screenshotDirectory = env["CMUX_UI_TEST_TERMINAL_CMD_CLICK_SCREENSHOT_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let rawOpenSupportedFiles = env["CMUX_UI_TEST_OPEN_SUPPORTED_FILES_IN_CMUX"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !rawOpenSupportedFiles.isEmpty {
            FileRouteSettingsStore(defaults: .standard).setSupportedFileRouteEnabled(rawOpenSupportedFiles == "1")
        }
        if let rawOpenMarkdown = env["CMUX_UI_TEST_OPEN_MARKDOWN_IN_CMUX_VIEWER"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !rawOpenMarkdown.isEmpty {
            FileRouteSettingsStore(defaults: .standard).setMarkdownRouteEnabled(rawOpenMarkdown == "1")
        }
        let extraFileNamesJSON = env["CMUX_UI_TEST_TERMINAL_CMD_CLICK_EXTRA_FILE_NAMES_JSON"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let scenario = TerminalCmdClickScenario(environment: env)
        let resolvedFileName = scenario.resolvedFileName
        let fixtureDirectoryURL = URL(fileURLWithPath: fixtureDirectory, isDirectory: true)
        let expectedFileURL = fixtureDirectoryURL.appendingPathComponent(resolvedFileName)
        let siblingFileURL = fixtureDirectoryURL.appendingPathComponent("OtherFile")
        let extraFileNames: [String]
        if let extraFileNamesJSON,
           let data = extraFileNamesJSON.data(using: .utf8),
           let values = try? JSONSerialization.jsonObject(with: data) as? [String] {
            extraFileNames = values
        } else {
            extraFileNames = []
        }
        let escapedToken = scenario.escapedToken
        let resolvedDisplayMode = scenario.resolvedDisplayMode
        let resolvedLineFormat = scenario.resolvedLineFormat
        cmuxDebugLog(
            "cmdclick.ui.setup start manifest=\(manifestPath) fixture=\(fixtureDirectory) " +
                "command=\(commandPath ?? "nil") display=\(resolvedDisplayMode) " +
                "lineFormat=\(resolvedLineFormat) " +
                "file=\(resolvedFileName)"
        )
        let displayToken = scenario.displayToken
        let shellCommand = scenario.shellCommand
        let deadline = Date().addingTimeInterval((commandPath?.isEmpty == false) ? 60.0 : 20.0)
        var seeded = false
        var resolved = false
        var tokenPointPayload: [String: Any]?
        var observers: [NSObjectProtocol] = []
        var lastHandledCommandID: String?
        var screenshotSequence = 0

        func rectPayload(_ rect: CGRect) -> [String: Double] {
            [
                "x": rect.origin.x,
                "y": rect.origin.y,
                "width": rect.size.width,
                "height": rect.size.height
            ]
        }

        func pointPayload(x: CGFloat, yFromTop: CGFloat) -> [String: Double] {
            [
                "x": x,
                "y": yFromTop
            ]
        }

        func doubleValue(_ value: Any?) -> Double? {
            if let value = value as? Double {
                return value
            }
            if let value = value as? NSNumber {
                return value.doubleValue
            }
            return nil
        }

        func pointFromPayload(_ key: String, in terminalPanel: TerminalPanel) -> NSPoint? {
            guard let payload = tokenPointPayload?[key] as? [String: Any],
                  let x = doubleValue(payload["x"]),
                  let yFromTop = doubleValue(payload["y"]) else {
                return nil
            }

            let clampedX = min(max(CGFloat(x), 1), max(terminalPanel.hostedView.bounds.width - 1, 1))
            let clampedYFromTop = min(
                max(CGFloat(yFromTop), 1),
                max(terminalPanel.hostedView.bounds.height - 1, 1)
            )
            return NSPoint(
                x: clampedX,
                y: terminalPanel.hostedView.bounds.height - clampedYFromTop
            )
        }

        func pointForTokenColumnOffset(_ offset: Int, in terminalPanel: TerminalPanel) -> NSPoint? {
            guard let selectionStart = pointFromPayload("tokenSelectionStartInTerminal", in: terminalPanel),
                  let tokenCellMetrics = tokenPointPayload?["tokenCellMetrics"] as? [String: Any],
                  let cellWidth = doubleValue(tokenCellMetrics["cellWidth"]) else {
                return nil
            }

            let unclampedX = selectionStart.x + (CGFloat(offset) * CGFloat(cellWidth))
            let clampedX = min(max(unclampedX, 1), max(terminalPanel.hostedView.bounds.width - 1, 1))
            return NSPoint(x: clampedX, y: selectionStart.y)
        }

        func commandPoint(
            from command: [String: Any],
            defaultPayloadKey: String,
            in terminalPanel: TerminalPanel
        ) -> NSPoint? {
            if let tokenColumnOffset = command["tokenColumnOffset"] as? Int {
                return pointForTokenColumnOffset(tokenColumnOffset, in: terminalPanel)
            }
            if let tokenColumnOffset = command["tokenColumnOffset"] as? NSNumber {
                return pointForTokenColumnOffset(tokenColumnOffset.intValue, in: terminalPanel)
            }
            return pointFromPayload(defaultPayloadKey, in: terminalPanel)
        }

        func loadCommand(at path: String) -> [String: Any]? {
            let url = URL(fileURLWithPath: path)
            guard let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            return object
        }

        func tokenPoints(in terminalPanel: TerminalPanel, visibleText: String) -> [String: Any]? {
            guard let surface = terminalPanel.surface.surface else { return nil }
            let bounds = terminalPanel.hostedView.bounds
            guard bounds.width > 0, bounds.height > 0 else { return nil }

            let size = ghostty_surface_size(surface)
            let rows = max(Int(size.rows), 1)
            let cols = max(Int(size.columns), 1)
            let debugCellSize = terminalPanel.hostedView.debugCellSize
            let cellWidth = debugCellSize.width > 0 ? debugCellSize.width : CGFloat(size.cell_width_px)
            let cellHeight = debugCellSize.height > 0 ? debugCellSize.height : CGFloat(size.cell_height_px)
            guard cellWidth > 0, cellHeight > 0 else { return nil }

            let xInset = max(0, (bounds.width - (CGFloat(cols) * cellWidth)) / 2)
            let yInset = max(0, (bounds.height - (CGFloat(rows) * cellHeight)) / 2)
            let pointClampX: (CGFloat) -> CGFloat = { x in
                min(bounds.width - 4, max(4, x))
            }
            let pointClampY: (CGFloat) -> CGFloat = { y in
                min(bounds.height - 4, max(4, y))
            }

            let rawVisibleLines = visibleText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let visibleLines = rawVisibleLines.count > rows ? Array(rawVisibleLines.suffix(rows)) : rawVisibleLines
            let rowOffset = max(0, rows - visibleLines.count)

            var matchedRowFromTop: Int?
            var matchedColumnStart: Int?
            var matchedColumnEnd: Int?
            var matchedLine = ""
            var matchingLines: [(lineIndex: Int, line: String, ranges: [Range<String.Index>])] = []

            for (lineIndex, line) in visibleLines.enumerated() {
                var searchStart = line.startIndex
                var ranges: [Range<String.Index>] = []
                while searchStart < line.endIndex,
                      let range = line.range(of: displayToken, range: searchStart..<line.endIndex) {
                    ranges.append(range)
                    searchStart = range.upperBound
                }
                if !ranges.isEmpty {
                    matchingLines.append((lineIndex, line, ranges))
                }
            }

            if !matchingLines.isEmpty {
                let selectedLine = matchingLines[matchingLines.count / 2]
                let selectedRange = selectedLine.ranges[selectedLine.ranges.count / 2]
                let startColumn = selectedLine.line.distance(from: selectedLine.line.startIndex, to: selectedRange.lowerBound)
                let endColumnExclusive = selectedLine.line.distance(from: selectedLine.line.startIndex, to: selectedRange.upperBound)
                if startColumn < cols {
                    matchedRowFromTop = rowOffset + selectedLine.lineIndex
                    matchedColumnStart = startColumn
                    matchedColumnEnd = max(startColumn, endColumnExclusive - 1)
                    matchedLine = selectedLine.line
                }
            }

            guard let matchedRowFromTop,
                  let matchedColumnStart,
                  let matchedColumnEnd else {
                return [
                    "tokenLayoutMatch": "0",
                    "tokenCellMetrics": [
                        "cellWidth": cellWidth,
                        "cellHeight": cellHeight,
                        "columns": cols,
                        "rows": rows,
                        "xInset": xInset,
                        "yInset": yInset,
                        "visibleLineCount": visibleLines.count
                    ]
                ]
            }

            let yFromTop = pointClampY(yInset + (CGFloat(matchedRowFromTop) * cellHeight) + (cellHeight / 2))
            let startX = pointClampX(xInset + (CGFloat(matchedColumnStart) * cellWidth) + (cellWidth / 2))
            let endX = pointClampX(xInset + (CGFloat(matchedColumnEnd) * cellWidth) + (cellWidth / 2))
            let hitX = pointClampX(startX + min(cellWidth * 2, max(0, endX - startX)))
            return [
                "tokenHitPointInTerminal": pointPayload(x: hitX, yFromTop: yFromTop),
                "tokenSelectionStartInTerminal": pointPayload(x: startX, yFromTop: yFromTop),
                "tokenSelectionEndInTerminal": pointPayload(x: endX, yFromTop: yFromTop),
                "tokenQuicklookWord": displayToken,
                "tokenLayoutMatch": "1",
                "tokenCellMetrics": [
                    "cellWidth": cellWidth,
                    "cellHeight": cellHeight,
                    "columns": cols,
                    "rows": rows,
                    "xInset": xInset,
                    "yInset": yInset,
                    "visibleLineCount": visibleLines.count,
                    "matchedRowFromTop": matchedRowFromTop,
                    "matchedColumnStart": matchedColumnStart,
                    "matchedColumnEnd": matchedColumnEnd,
                    "matchedLine": matchedLine
                ]
            ]
        }

        func cleanup() {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers.removeAll()
            self.poller?.cancel()
            self.poller = nil
        }

        func writeState(
            terminalPanel: TerminalPanel?,
            window: NSWindow?,
            ready: Bool,
            setupError: String? = nil,
            additionalPayload: [String: Any] = [:]
        ) {
            var payload: [String: Any] = [
                "ready": ready ? "1" : "0",
                "escapedToken": escapedToken,
                "displayMode": resolvedDisplayMode,
                "lineFormat": resolvedLineFormat,
                "displayToken": displayToken,
                "fileName": resolvedFileName,
                "expectedPath": expectedFileURL.path,
                "fixtureDirectory": fixtureDirectoryURL.path
            ]
            if let terminalPanel {
                let terminalFrame = terminalPanel.hostedView.debugPortalFrameInWindow
                payload["surfaceId"] = terminalPanel.id.uuidString
                payload["terminalVisibleInUI"] = terminalPanel.hostedView.debugPortalVisibleInUI ? "1" : "0"
                payload["terminalFrameInWindow"] = rectPayload(terminalFrame)
            }
            if let window {
                payload["windowFrame"] = rectPayload(window.frame)
                payload["windowVisible"] = window.isVisible ? "1" : "0"
            }
            if let setupError {
                payload["setupError"] = setupError
            }
            if let tokenPointPayload {
                for (key, value) in tokenPointPayload {
                    payload[key] = value
                }
            }
            for (key, value) in additionalPayload {
                payload[key] = value
            }
            writeData(at: manifestPath, updates: payload)
        }

        func resizeWindowIfNeeded(_ window: NSWindow) {
            let screenFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            guard let screenFrame else { return }
            let targetSize = NSSize(
                width: min(960, screenFrame.width - 80),
                height: min(720, screenFrame.height - 80)
            )
            let targetOrigin = NSPoint(
                x: screenFrame.minX + 40,
                y: screenFrame.maxY - 40 - targetSize.height
            )
            let targetFrame = NSRect(origin: targetOrigin, size: targetSize)
            if !window.frame.equalTo(targetFrame) {
                window.setFrame(targetFrame, display: true)
            }
        }

        func safeScreenshotLabel(_ label: String) -> String {
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
            let scalars = label.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
            let cleaned = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-_."))
            return cleaned.isEmpty ? "capture" : cleaned
        }

        @MainActor
        func captureWindowSnapshotIfRequested(label: String, window: NSWindow) -> String? {
            guard let screenshotDirectory,
                  !screenshotDirectory.isEmpty,
                  let contentView = window.contentView else {
                return nil
            }
            let bounds = contentView.bounds
            guard !bounds.isEmpty,
                  let bitmap = contentView.bitmapImageRepForCachingDisplay(in: bounds) else {
                return nil
            }
            contentView.cacheDisplay(in: bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else {
                return nil
            }
            do {
                let directoryURL = URL(fileURLWithPath: screenshotDirectory, isDirectory: true)
                try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
                let sequence = String(format: "%03d", screenshotSequence)
                screenshotSequence += 1
                let fileURL = directoryURL
                    .appendingPathComponent("\(sequence)-\(safeScreenshotLabel(label)).png")
                try data.write(to: fileURL, options: .atomic)
                return fileURL.path
            } catch {
                cmuxDebugLog("cmdclick.ui.snapshot failed label=\(label) error=\(error.localizedDescription)")
                return nil
            }
        }

        func cmdClickUITestTerminalPanel(in workspace: Workspace?) -> TerminalPanel? {
            guard let workspace else { return nil }
            if let focusedTerminalPanel = workspace.focusedTerminalPanel {
                return focusedTerminalPanel
            }
            return workspace.panels.values
                .compactMap { $0 as? TerminalPanel }
                .first { panel in
                    panel.surface.isViewInWindow &&
                        panel.hostedView.debugPortalVisibleInUI &&
                        !panel.hostedView.debugPortalFrameInWindow.isEmpty
                }
        }

        @MainActor
        func executePendingCommandIfNeeded(
            workspace: Workspace,
            terminalPanel: TerminalPanel,
            window: NSWindow
        ) {
            guard let commandPath,
                  !commandPath.isEmpty,
                  let command = loadCommand(at: commandPath),
                  let commandID = command["id"] as? String,
                  commandID != lastHandledCommandID else {
                return
            }

            let action = (command["action"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            var payload: [String: Any] = [
                "lastCommandId": commandID,
                "lastCommandAction": action,
                "lastCommandSucceeded": "0"
            ]

            switch action {
            case "hover_token":
                guard let hitPoint = commandPoint(
                    from: command,
                    defaultPayloadKey: "tokenHitPointInTerminal",
                    in: terminalPanel
                ) else {
                    payload["lastCommandError"] = "Missing command point"
                    break
                }

                let result = terminalPanel.hostedView.debugSimulateCommandHoverDetails(at: hitPoint)
                payload["lastCommandResult"] = result
                payload["lastCommandHoverActive"] = result["hoverActive"]
                if let resolvedPath = result["resolvedPath"] as? String {
                    payload["lastCommandResolvedPath"] = resolvedPath
                    payload["lastCommandSucceeded"] = "1"
                } else if let error = result["error"] as? String {
                    payload["lastCommandError"] = error
                } else {
                    payload["lastCommandError"] = "Command hover did not resolve a path"
                }

            case "cmd_click_token":
                guard let hitPoint = commandPoint(
                    from: command,
                    defaultPayloadKey: "tokenHitPointInTerminal",
                    in: terminalPanel
                ) else {
                    payload["lastCommandError"] = "Missing command point"
                    break
                }

                let result = terminalPanel.hostedView.debugSimulateCommandClick(at: hitPoint)
                payload["lastCommandResult"] = result
                if let openedPath = result["openedPath"] as? String {
                    payload["lastCommandOpenedPath"] = openedPath
                    let canonicalOpenedPath = (openedPath as NSString).resolvingSymlinksInPath
                    let openedInFilePreview = workspace.panels.values.contains { panel in
                        guard let filePreview = panel as? FilePreviewPanel else { return false }
                        return (filePreview.filePath as NSString).resolvingSymlinksInPath == canonicalOpenedPath
                    }
                    let openedInMarkdownViewer = workspace.panels.values.contains { panel in
                        guard let markdown = panel as? MarkdownPanel else { return false }
                        return (markdown.filePath as NSString).resolvingSymlinksInPath == canonicalOpenedPath
                    }
                    payload["lastCommandOpenedInFilePreview"] = openedInFilePreview ? "1" : "0"
                    payload["lastCommandOpenedInMarkdownViewer"] = openedInMarkdownViewer ? "1" : "0"
                    payload["lastCommandSucceeded"] = "1"
                } else if let error = result["error"] as? String {
                    payload["lastCommandError"] = error
                } else {
                    payload["lastCommandError"] = "Command click did not open a path"
                }

            case "stationary_cmd_click_token":
                guard let hitPoint = commandPoint(
                    from: command,
                    defaultPayloadKey: "tokenHitPointInTerminal",
                    in: terminalPanel
                ) else {
                    payload["lastCommandError"] = "Missing command point"
                    break
                }

                let capturePath = ProcessInfo.processInfo.environment["CMUX_UI_TEST_CAPTURE_OPEN_URL_PATH"]
                let beforeURLCount = capturePath.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }?
                    .split(separator: "\n").count ?? 0
                let result = terminalPanel.hostedView.debugSimulateStationaryCommandClick(at: hitPoint)
                payload["lastCommandResult"] = result
                let openedURLs = capturePath.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }?
                    .split(separator: "\n").map(String.init) ?? []
                if openedURLs.count > beforeURLCount, let openedURL = openedURLs.last {
                    payload["lastCommandOpenedURL"] = openedURL
                    payload["lastCommandSucceeded"] = "1"
                } else if let error = result["error"] as? String {
                    payload["lastCommandError"] = error
                } else {
                    payload["lastCommandError"] = "Stationary command click did not open a URL"
                }

            case "select_token_and_hold_command":
                guard let selectionStart = pointFromPayload("tokenSelectionStartInTerminal", in: terminalPanel),
                      let selectionEnd = pointFromPayload("tokenSelectionEndInTerminal", in: terminalPanel) else {
                    payload["lastCommandError"] = "Missing token selection points"
                    break
                }

                let selectionActive = terminalPanel.hostedView.debugSimulateSelection(
                    from: selectionStart,
                    to: selectionEnd
                )
                let hoverSuppressed = terminalPanel.hostedView.debugSimulateCommandHover(at: selectionEnd)
                payload["lastCommandSelectionActive"] = selectionActive ? "1" : "0"
                payload["lastCommandHoverSuppressed"] = hoverSuppressed ? "1" : "0"
                if selectionActive && hoverSuppressed {
                    payload["lastCommandSucceeded"] = "1"
                } else {
                    payload["lastCommandError"] = "Selection or hover suppression failed"
                }

            case "capture_window":
                let label = (command["label"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let path = captureWindowSnapshotIfRequested(
                    label: label?.isEmpty == false ? label! : "capture",
                    window: window
                ) {
                    payload["lastCommandScreenshotPath"] = path
                    payload["lastCommandSucceeded"] = "1"
                } else {
                    payload["lastCommandError"] = "Window screenshot capture unavailable"
                }

            default:
                payload["lastCommandError"] = "Unknown command action: \(action)"
            }

            writeState(
                terminalPanel: terminalPanel,
                window: window,
                ready: true,
                additionalPayload: payload
            )
            lastHandledCommandID = commandID
        }

        @MainActor
        func evaluate() {
            guard !resolved else { return }
            let currentTabManager = self.appDelegate.tabManager
            let workspace = currentTabManager?.selectedWorkspace ?? currentTabManager?.tabs.first
            let terminalPanel = cmdClickUITestTerminalPanel(in: workspace)
            let mainWindow = terminalPanel?.surface.uiWindow
                ?? currentTabManager.flatMap { self.appDelegate.windowId(for: $0).flatMap { self.appDelegate.mainWindow(for: $0) } }
            if Date() >= deadline {
                let textSnapshot = terminalPanel
                    .flatMap { TerminalController.shared.readTerminalTextForSnapshot(terminalPanel: $0, lineLimit: 200) } ?? ""
                var timeoutPayload: [String: Any] = [:]
                if let currentTabManager {
                    timeoutPayload["tabManager"] = self.appDelegate.debugManagerToken(currentTabManager)
                    timeoutPayload["workspaceCount"] = currentTabManager.tabs.count
                }
                let waitingFor = [
                    workspace == nil ? "workspace" : nil,
                    terminalPanel == nil ? "terminalPanel" : nil,
                    mainWindow == nil ? "mainWindow" : nil
                ]
                    .compactMap { $0 }
                    .joined(separator: ",")
                if !waitingFor.isEmpty {
                    timeoutPayload["waitingFor"] = waitingFor
                }
                writeState(
                    terminalPanel: terminalPanel,
                    window: mainWindow,
                    ready: false,
                    setupError: "Timed out waiting for terminal cmd-click setup. text=\(textSnapshot)",
                    additionalPayload: timeoutPayload
                )
                resolved = true
                cleanup()
                return
            }

            if currentTabManager == nil {
                writeData(at: manifestPath, updates: [
                    "ready": "0",
                    "setupError": "Waiting for tab manager"
                ])
                return
            }

            guard let workspace,
                  let terminalPanel,
                  let mainWindow else {
                var waitingPayload: [String: Any] = [
                    "ready": "0",
                    "setupError": "Waiting for terminal workspace"
                ]
                if let currentTabManager {
                    waitingPayload["tabManager"] = self.appDelegate.debugManagerToken(currentTabManager)
                    waitingPayload["workspaceCount"] = currentTabManager.tabs.count
                }
                let waitingFor = [
                    workspace == nil ? "workspace" : nil,
                    terminalPanel == nil ? "terminalPanel" : nil,
                    mainWindow == nil ? "mainWindow" : nil
                ]
                    .compactMap { $0 }
                    .joined(separator: ",")
                if !waitingFor.isEmpty {
                    waitingPayload["waitingFor"] = waitingFor
                }
                writeData(at: manifestPath, updates: waitingPayload)
                return
            }

            resizeWindowIfNeeded(mainWindow)
            mainWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            terminalPanel.focus()

            do {
                try FileManager.default.createDirectory(
                    at: fixtureDirectoryURL,
                    withIntermediateDirectories: true
                )
                try FileManager.default.createDirectory(
                    at: expectedFileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if !FileManager.default.fileExists(atPath: expectedFileURL.path) {
                    try "fixture\n".write(to: expectedFileURL, atomically: true, encoding: .utf8)
                }
                if !FileManager.default.fileExists(atPath: siblingFileURL.path) {
                    try "fixture\n".write(to: siblingFileURL, atomically: true, encoding: .utf8)
                }
                for extraFileName in extraFileNames where !extraFileName.isEmpty {
                    let extraFileURL = fixtureDirectoryURL.appendingPathComponent(extraFileName)
                    try FileManager.default.createDirectory(
                        at: extraFileURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    if !FileManager.default.fileExists(atPath: extraFileURL.path) {
                        try "fixture\n".write(to: extraFileURL, atomically: true, encoding: .utf8)
                    }
                }
            } catch {
                writeState(
                    terminalPanel: terminalPanel,
                    window: mainWindow,
                    ready: false,
                    setupError: "Failed to create fixture: \(error.localizedDescription)"
                )
                resolved = true
                cleanup()
                return
            }

            workspace.updatePanelDirectory(panelId: terminalPanel.id, directory: fixtureDirectoryURL.path)

            let terminalFrame = terminalPanel.hostedView.debugPortalFrameInWindow
            let terminalReady = terminalPanel.surface.surface != nil
            let terminalVisible = terminalPanel.surface.isViewInWindow &&
                terminalPanel.hostedView.debugPortalVisibleInUI &&
                !terminalFrame.isEmpty &&
                terminalFrame.width > 0 &&
                terminalFrame.height > 0

            if terminalReady && terminalVisible && !seeded {
                seeded = true
                self.appDelegate.sendTextWhenReady(shellCommand, to: workspace, beforeSend: {
                    workspace.updatePanelDirectory(panelId: terminalPanel.id, directory: fixtureDirectoryURL.path)
                })
            }

            let visibleText = TerminalController.shared.readTerminalTextForSnapshot(
                terminalPanel: terminalPanel,
                lineLimit: 200
            ) ?? ""
            let renderedTokenCount = max(0, visibleText.components(separatedBy: displayToken).count - 1)
            let hasRenderedToken = renderedTokenCount >= 6
            if hasRenderedToken,
               (tokenPointPayload?["tokenLayoutMatch"] as? String) != "1" {
                tokenPointPayload = tokenPoints(in: terminalPanel, visibleText: visibleText)
            }
            let tokenLayoutReady = (tokenPointPayload?["tokenLayoutMatch"] as? String) == "1"

            writeState(
                terminalPanel: terminalPanel,
                window: mainWindow,
                ready: terminalReady && terminalVisible && hasRenderedToken && tokenLayoutReady,
                additionalPayload: [
                    "seeded": seeded ? "1" : "0",
                    "hasRenderedToken": hasRenderedToken ? "1" : "0",
                    "renderedTokenCount": renderedTokenCount,
                    "visibleTextTail": String(visibleText.suffix(1200))
                ]
            )

            guard terminalReady, terminalVisible, hasRenderedToken, tokenLayoutReady else { return }
            if commandPath?.isEmpty == false {
                executePendingCommandIfNeeded(
                    workspace: workspace,
                    terminalPanel: terminalPanel,
                    window: mainWindow
                )
                return
            }
            resolved = true
            cleanup()
        }

        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in evaluate() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .terminalSurfaceHostedViewDidMoveToWindow,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in evaluate() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .terminalSurfaceDidBecomeReady,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in evaluate() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDidFocusSurface,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in evaluate() }
        })
        let poller = DispatchSource.makeTimerSource(queue: .main)
        poller.schedule(deadline: .now(), repeating: .milliseconds(100))
        poller.setEventHandler {
            Task { @MainActor in evaluate() }
        }
        self.poller = poller
        cmuxDebugLog("cmdclick.ui.setup poller_started manifest=\(manifestPath)")
        poller.resume()
    }

    private func writeData(at path: String, updates: [String: Any]) {
        let url = URL(fileURLWithPath: path)
        var payload: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            payload = object
        }
        for (key, value) in updates {
            payload[key] = value
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            cmuxDebugLog("cmdclick.ui.write skip reason=json path=\(path)")
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        } catch {
            cmuxDebugLog("cmdclick.ui.write error path=\(path) error=\(error.localizedDescription)")
        }
    }
}
#endif
