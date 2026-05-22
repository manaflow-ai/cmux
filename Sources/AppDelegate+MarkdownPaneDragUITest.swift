import AppKit
import Bonsplit

#if DEBUG
private var didSetupMarkdownPaneDragUITest = false

extension AppDelegate {
    func setupMarkdownPaneDragUITestIfNeeded() {
        guard !didSetupMarkdownPaneDragUITest else { return }
        didSetupMarkdownPaneDragUITest = true

        let env = ProcessInfo.processInfo.environment
        guard env["CMUX_UI_TEST_MARKDOWN_PANE_DRAG_SETUP"] == "1" else { return }
        guard let path = env["CMUX_UI_TEST_MARKDOWN_PANE_DRAG_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            cmuxDebugLog("markdown.dragUITest.setup error=missingPath")
            return
        }
        guard let fixtureDirectory = env["CMUX_UI_TEST_MARKDOWN_PANE_DRAG_FIXTURE_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !fixtureDirectory.isEmpty else {
            writeMarkdownPaneDragUITestData([
                "setupError": "Missing fixture directory",
                "done": "1",
            ], at: path)
            return
        }

        let requestedScenario = env["CMUX_UI_TEST_MARKDOWN_PANE_DRAG_SCENARIO"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let scenario: String
        switch requestedScenario {
        case nil, "", "center":
            scenario = "center"
        case "split":
            scenario = "split"
        case "samePaneSplit":
            scenario = "samePaneSplit"
        default:
            writeMarkdownPaneDragUITestData([
                "setupError": "Invalid CMUX_UI_TEST_MARKDOWN_PANE_DRAG_SCENARIO: \(requestedScenario ?? "")",
                "done": "1",
            ], at: path)
            return
        }
        let deadline = Date().addingTimeInterval(20.0)

        func mainWindowForMarkdownDragUITest() -> NSWindow? {
            NSApp.windows.first { window in
                guard let raw = window.identifier?.rawValue else { return false }
                return raw == "cmux.main" || raw.hasPrefix("cmux.main.")
            }
        }

        func runSetupWhenWindowReady() {
            guard Date() < deadline else {
                self.writeMarkdownPaneDragUITestData([
                    "setupError": "Timed out waiting for main window",
                    "done": "1",
                ], at: path)
                return
            }
            guard let mainWindow = mainWindowForMarkdownDragUITest(),
                  let tabManager = self.tabManager else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    runSetupWhenWindowReady()
                }
                return
            }

            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.runMarkdownPaneDragUITestScenario(
                    scenario: scenario,
                    manifestPath: path,
                    fixtureDirectory: fixtureDirectory,
                    tabManager: tabManager,
                    mainWindow: mainWindow
                )
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            runSetupWhenWindowReady()
        }
    }

    @MainActor
    private func runMarkdownPaneDragUITestScenario(
        scenario: String,
        manifestPath: String,
        fixtureDirectory: String,
        tabManager: TabManager,
        mainWindow: NSWindow
    ) async {
        do {
            let fixtures = try await Task.detached(priority: .utility) {
                try createMarkdownPaneDragFixtures(
                    fixtureDirectory: fixtureDirectory,
                    scenario: scenario
                )
            }.value
            let workspace = tabManager.addTab()
            guard let sourceTerminalId = workspace.focusedPanelId else {
                writeMarkdownPaneDragUITestData(["setupError": "Missing initial terminal panel", "done": "1"], at: manifestPath)
                return
            }
            guard let rightTerminal = workspace.newTerminalSplit(from: sourceTerminalId, orientation: .horizontal) else {
                writeMarkdownPaneDragUITestData(["setupError": "Failed to create target split", "done": "1"], at: manifestPath)
                return
            }
            guard let leftPane = workspace.paneId(forPanelId: sourceTerminalId),
                  let rightPane = workspace.paneId(forPanelId: rightTerminal.id) else {
                writeMarkdownPaneDragUITestData(["setupError": "Failed to resolve source or target pane", "done": "1"], at: manifestPath)
                return
            }
            guard let primaryPanel = workspace.newMarkdownSurface(
                inPane: leftPane,
                filePath: fixtures.primary.path,
                focus: true
            ) else {
                writeMarkdownPaneDragUITestData(["setupError": "Failed to open primary markdown panel", "done": "1"], at: manifestPath)
                return
            }

            let primaryReady = await waitForMarkdownRendererLoadedForUITest(
                panel: primaryPanel,
                window: mainWindow
            )
            guard primaryReady else {
                writeMarkdownPaneDragUITestData(["setupError": "Primary markdown renderer did not load", "done": "1"], at: manifestPath)
                return
            }

            let dropTargetPane = scenario == "samePaneSplit" ? leftPane : rightPane
            if scenario == "samePaneSplit" {
                workspace.focusPanel(primaryPanel.id)
            } else {
                workspace.focusPanel(rightTerminal.id)
            }
            await settleMarkdownPaneDragUITestLayout(window: mainWindow, passes: 12)
            primaryPanel.rendererSession.resetDiagnostics(reason: "before-\(scenario)-drop")

            let paneCountBefore = workspace.bonsplitController.allPaneIds.count
            let targetPaneTabCountBefore = workspace.bonsplitController.tabs(inPane: dropTargetPane).count
            let zone: DropZone = {
                switch scenario {
                case "split":
                    return .right
                case "samePaneSplit":
                    return .bottom
                default:
                    return .center
                }
            }()
            cmuxDebugLog(
                "markdown.dragUITest.drop.start scenario=\(scenario) zone=\(zone) " +
                    "primary=\(primaryPanel.id.uuidString.prefix(5)) targetPane=\(dropTargetPane.id.uuidString.prefix(5))"
            )
            let handled = workspace.handleExternalFileDrop(BonsplitController.ExternalFileDropRequest(
                urls: [fixtures.dropped],
                destination: PaneDropRouting.filePreviewDestination(
                    targetPane: dropTargetPane,
                    zone: zone
                )
            ))

            let expectedPaneCount = scenario == "center" ? paneCountBefore : paneCountBefore + 1
            let droppedReady = await waitForMarkdownDropSettledForUITest(
                workspace: workspace,
                droppedPath: fixtures.dropped.path,
                expectedPaneCount: expectedPaneCount,
                window: mainWindow
            )
            let droppedPanel = markdownPanel(in: workspace, filePath: fixtures.dropped.path)
            let primaryDiagnostics = primaryPanel.rendererSession.diagnosticsSnapshot
            let droppedDiagnostics = droppedPanel?.rendererSession.diagnosticsSnapshot ?? MarkdownRendererDiagnosticsSnapshot()
            let paneCountAfter = workspace.bonsplitController.allPaneIds.count
            let targetPaneTabCountAfter = workspace.bonsplitController.tabs(inPane: dropTargetPane).count
            let droppedPaneId = droppedPanel.flatMap { workspace.paneId(forPanelId: $0.id) }
            let primaryPaneId = workspace.paneId(forPanelId: primaryPanel.id)
            let violationReasons = markdownPaneDragFlickerViolationReasons(primaryDiagnostics)

            var updates: [String: String] = [
                "ready": "1",
                "done": "1",
                "scenario": scenario,
                "dropHandled": handled ? "1" : "0",
                "droppedReady": droppedReady ? "1" : "0",
                "primaryPath": fixtures.primary.path,
                "droppedPath": fixtures.dropped.path,
                "workspaceId": workspace.id.uuidString,
                "primaryPanelId": primaryPanel.id.uuidString,
                "droppedPanelId": droppedPanel?.id.uuidString ?? "",
                "sourceTerminalId": sourceTerminalId.uuidString,
                "rightTerminalId": rightTerminal.id.uuidString,
                "leftPaneId": leftPane.description,
                "rightPaneId": rightPane.description,
                "targetPaneId": dropTargetPane.description,
                "primaryPaneIdAfter": primaryPaneId?.description ?? "",
                "droppedPaneIdAfter": droppedPaneId?.description ?? "",
                "paneCountBefore": String(paneCountBefore),
                "paneCountAfter": String(paneCountAfter),
                "expectedPaneCountAfter": String(expectedPaneCount),
                "targetPaneTabCountBefore": String(targetPaneTabCountBefore),
                "targetPaneTabCountAfter": String(targetPaneTabCountAfter),
                "primaryFlickerDetected": violationReasons.isEmpty ? "0" : "1",
                "primaryFlickerReasons": violationReasons.joined(separator: ","),
            ]
            updates.merge(
                primaryDiagnostics.fields(prefix: "primary", includeExistingPanelFlickerSignalCount: true)
            ) { _, new in new }
            updates.merge(
                droppedDiagnostics.fields(prefix: "dropped", includeExistingPanelFlickerSignalCount: false)
            ) { _, new in new }
            writeMarkdownPaneDragUITestData(updates, at: manifestPath)
            cmuxDebugLog(
                "markdown.dragUITest.drop.done scenario=\(scenario) handled=\(handled ? 1 : 0) " +
                    "primaryFlicker=\(violationReasons.isEmpty ? 0 : 1) reasons=\(violationReasons.joined(separator: ","))"
            )
        } catch {
            writeMarkdownPaneDragUITestData([
                "setupError": error.localizedDescription,
                "done": "1",
            ], at: manifestPath)
        }
    }

    @MainActor
    private func waitForMarkdownDropSettledForUITest(
        workspace: Workspace,
        droppedPath: String,
        expectedPaneCount: Int,
        window: NSWindow
    ) async -> Bool {
        for _ in 0..<120 {
            await settleMarkdownPaneDragUITestLayout(window: window, passes: 1)
            if workspace.bonsplitController.allPaneIds.count == expectedPaneCount,
               let panel = markdownPanel(in: workspace, filePath: droppedPath),
               panel.rendererSession.isLoadedForDiagnostics {
                return true
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }

    @MainActor
    private func waitForMarkdownRendererLoadedForUITest(
        panel: MarkdownPanel,
        window: NSWindow
    ) async -> Bool {
        for _ in 0..<120 {
            await settleMarkdownPaneDragUITestLayout(window: window, passes: 1)
            if panel.rendererSession.isLoadedForDiagnostics {
                return true
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }

    @MainActor
    private func settleMarkdownPaneDragUITestLayout(window: NSWindow, passes: Int) async {
        for _ in 0..<max(1, passes) {
            window.contentView?.layoutSubtreeIfNeeded()
            window.contentView?.displayIfNeeded()
            await Task.yield()
        }
    }

    private func markdownPanel(in workspace: Workspace, filePath: String) -> MarkdownPanel? {
        let canonical = (filePath as NSString).resolvingSymlinksInPath
        return workspace.panels.values.compactMap { $0 as? MarkdownPanel }.first { panel in
            (panel.filePath as NSString).resolvingSymlinksInPath == canonical
        }
    }

    private func markdownPaneDragFlickerViolationReasons(_ diagnostics: MarkdownRendererDiagnosticsSnapshot) -> [String] {
        var reasons: [String] = []
        if diagnostics.webViewCreateCount > 0 { reasons.append("webViewCreate") }
        if diagnostics.webViewReattachCount > 0 { reasons.append("webViewReattach") }
        if diagnostics.dismantleRetainedWebViewCount > 0 { reasons.append("dismantleRetainedWebView") }
        if diagnostics.loadShellCount > 0 { reasons.append("loadShell") }
        if diagnostics.pushMarkdownCount > 0 { reasons.append("pushMarkdown") }
        if diagnostics.didFinishCount > 0 { reasons.append("didFinish") }
        if diagnostics.webContentProcessTerminationCount > 0 { reasons.append("webContentProcessTermination") }
        if diagnostics.navigationFailureCount > 0 { reasons.append("navigationFailure") }
        return reasons
    }

    private func writeMarkdownPaneDragUITestData(_ updates: [String: String], at path: String) {
        var payload = loadMarkdownPaneDragUITestData(at: path)
        for (key, value) in updates {
            payload[key] = value
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private func loadMarkdownPaneDragUITestData(at path: String) -> [String: String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return object
    }
}

private func createMarkdownPaneDragFixtures(
    fixtureDirectory: String,
    scenario: String
) throws -> (primary: URL, dropped: URL) {
    let directory = URL(fileURLWithPath: fixtureDirectory, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let primary = directory.appendingPathComponent("primary-\(scenario).md")
    let dropped = directory.appendingPathComponent("dropped-\(scenario).md")
    if !FileManager.default.fileExists(atPath: primary.path) {
        try "# Primary \(scenario)\n\nThe primary markdown editor must stay stable while another markdown file is dropped.\n"
            .write(to: primary, atomically: true, encoding: .utf8)
    }
    if !FileManager.default.fileExists(atPath: dropped.path) {
        try "# Dropped \(scenario)\n\nThis file is opened through the pane file-drop path.\n"
            .write(to: dropped, atomically: true, encoding: .utf8)
    }
    return (primary, dropped)
}
#endif
