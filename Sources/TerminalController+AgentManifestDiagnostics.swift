import CmuxCore
import CmuxControlSocket
import CmuxTerminal
import Darwin
import Foundation

private struct AgentManifestPaneCapture: Sendable {
    let panelID: String
    let foregroundPID: Int?
    let screen: String
    let osc: String
}

private struct AgentManifestDiagnosticFailure: Error, Sendable {
    let message: String
}

extension TerminalController {
    /// Reports the process matcher and first state rule selected for a pane.
    /// The capture hop is read-only and never activates or focuses a window;
    /// expensive process decoding and manifest evaluation stay on the socket
    /// worker thread.
    nonisolated func debugAgentManifest(_ rawArguments: String) -> String {
        switch AgentManifestDiagnosticArguments.parse(commandLine: rawArguments) {
        case let .success(arguments):
            return debugAgentManifest(arguments: arguments)
        case let .failure(error):
            return "ERROR: \(error.localizedDescription)"
        }
    }

    private nonisolated func debugAgentManifest(
        arguments: AgentManifestDiagnosticArguments
    ) -> String {
        let capture: Result<AgentManifestPaneCapture, AgentManifestDiagnosticFailure> = v2MainSync(
            commandKey: "debug_agent_manifest"
        ) {
            guard let tabManager else {
                return .failure(AgentManifestDiagnosticFailure(message: Self.agentManifestError(
                    key: "cli.agentManifests.error.tabManagerUnavailable",
                    defaultValue: "Agent manifest diagnostics are unavailable because no tab manager is active."
                )))
            }

            // Refresh the handle registry before resolving a caller-provided
            // surface:2/pane:3 reference. This is a read-only minting pass and
            // does not select or focus anything.
            v2RefreshKnownRefs()
            guard let panel = resolveAgentManifestPanel(
                from: arguments.surface ?? "",
                tabManager: tabManager
            ) else {
                return .failure(AgentManifestDiagnosticFailure(message: Self.agentManifestError(
                    key: "cli.agentManifests.error.surfaceNotFound",
                    defaultValue: "Terminal surface not found."
                )))
            }
            guard panel.surface.surface != nil else {
                return .failure(AgentManifestDiagnosticFailure(message: Self.agentManifestError(
                    key: "cli.agentManifests.error.screenUnavailable",
                    defaultValue: "Terminal screen text is unavailable for this surface."
                )))
            }

            // State rules describe the currently rendered pane. Including the
            // entire scrollback makes an old "done" or permission line win over
            // the live prompt, so only the active/screen regions participate.
            let active = readTerminalSelectionText(
                terminalPanel: panel,
                pointTag: GHOSTTY_POINT_ACTIVE
            )
            let screen = readTerminalSelectionText(
                terminalPanel: panel,
                pointTag: GHOSTTY_POINT_SCREEN
            )
            guard active != nil || screen != nil else {
                return .failure(AgentManifestDiagnosticFailure(message: Self.agentManifestError(
                    key: "cli.agentManifests.error.screenUnavailable",
                    defaultValue: "Terminal screen text is unavailable for this surface."
                )))
            }
            var screenParts: [String] = []
            for value in [active, screen].compactMap({ $0 }) {
                guard !value.isEmpty, !screenParts.contains(value) else { continue }
                screenParts.append(value)
            }
            return .success(AgentManifestPaneCapture(
                panelID: panel.id.uuidString,
                foregroundPID: panel.surface.foregroundProcessID(),
                screen: screenParts.joined(separator: "\n"),
                osc: arguments.osc ?? ""
            ))
        }

        switch capture {
        case let .failure(error):
            return "ERROR: \(error.message)"
        case let .success(capture):
            let manifestState = currentAgentManifestStateForSocketCommand()
            return Self.renderAgentManifestDiagnostic(
                capture,
                manifestSnapshot: manifestState?.snapshot,
                manifestLoadError: manifestState?.error
            )
        }
    }

    private func resolveAgentManifestPanel(
        from rawSurface: String,
        tabManager: TabManager
    ) -> TerminalPanel? {
        guard let selectedTabID = tabManager.selectedTabId,
              let tab = tabManager.tabs.first(where: { $0.id == selectedTabID }) else {
            return nil
        }

        let trimmed = rawSurface.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            guard let focusedPanelID = tab.focusedPanelId else { return nil }
            return tab.terminalInputTarget(forPanelID: focusedPanelID)?.panel
        }

        let normalized = Self.surfaceReferencePayload(trimmed)
        if let resolvedID = v2ResolveHandleRef(trimmed)
            ?? v2ResolveHandleRef(normalized),
           let panel = agentManifestTerminalPanel(surfaceID: resolvedID)
            ?? agentManifestTerminalPanel(paneID: resolvedID) {
            return panel
        }
        if let uuid = UUID(uuidString: normalized) {
            return agentManifestTerminalPanel(surfaceID: uuid)
                ?? agentManifestTerminalPanel(paneID: uuid)
        }
        if let index = Int(normalized), index >= 0 {
            let panels = orderedPanels(in: tab)
            guard index < panels.count else { return nil }
            return tab.terminalInputTarget(forPanelID: panels[index].id)?.panel
        }
        return nil
    }

    private func agentManifestTerminalPanel(surfaceID: UUID) -> TerminalPanel? {
        if let panel = windowDockContainingPanel(surfaceID)?.panels[surfaceID] as? TerminalPanel {
            return panel
        }
        guard let manager = controlTabManager(surfaceID: surfaceID),
              let workspace = manager.tabs.first(where: {
                  $0.terminalInputTarget(forPanelID: surfaceID) != nil
              }) else {
            return nil
        }
        return workspace.terminalInputTarget(forPanelID: surfaceID)?.panel
    }

    private func agentManifestTerminalPanel(paneID: UUID) -> TerminalPanel? {
        if let dock = DockSplitStore.liveStores.first(where: { $0.containsPane(paneID) }),
           let pane = dock.bonsplitController.allPaneIds.first(where: { $0.id == paneID }),
           let selectedTabID = dock.bonsplitController.selectedTab(inPane: pane)?.id {
            return dock.panel(for: selectedTabID) as? TerminalPanel
        }
        guard let manager = controlTabManager(paneID: paneID) else { return nil }
        for workspace in manager.tabs {
            if let panel = workspace.controlDefaultTerminalTarget(paneID: paneID)?.panel {
                return panel
            }
        }
        return nil
    }

    private nonisolated static func surfaceReferencePayload(_ value: String) -> String {
        for prefix in ["surface:", "panel:"] {
            if value.lowercased().hasPrefix(prefix) {
                return String(value.dropFirst(prefix.count))
            }
        }
        return value
    }

    private nonisolated static func renderAgentManifestDiagnostic(
        _ capture: AgentManifestPaneCapture,
        manifestSnapshot: CmuxAgentManifestSnapshot?,
        manifestLoadError: CmuxAgentManifestLoadError?
    ) -> String {
        let details = capture.foregroundPID.flatMap {
            CmuxTopProcessSnapshot.processArgumentsAndEnvironment(for: $0)
        }
        let processPath = capture.foregroundPID.flatMap { Self.executablePath(for: $0) }
        let processName = processPath.map { ($0 as NSString).lastPathComponent }
            ?? details?.arguments.first.map { ($0 as NSString).lastPathComponent }
            ?? ""
        let process = VaultObservedAgentProcess(
            processName: processName,
            processPath: processPath,
            arguments: details?.arguments ?? [],
            environment: details?.environment ?? [:]
        )
        let workingDirectory = [
            process.environment["CMUX_AGENT_LAUNCH_CWD"],
            process.environment["PWD"],
        ].compactMap { value in
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed?.isEmpty == false ? trimmed : nil
        }.first
        let registry = CmuxVaultAgentRegistry.load(
            workingDirectory: workingDirectory,
            manifestSnapshot: manifestSnapshot
        )
        let diagnostic = registry.matchingRegistrationDiagnostic(
            for: process,
            screen: capture.screen,
            osc: capture.osc
        )
        let result = diagnostic.manifestResult

        var payload: [String: Any] = [
            "panel_id": capture.panelID,
            "foreground_pid": jsonValue(capture.foregroundPID),
            "process_name": processName,
            "process_path": jsonValue(processPath),
            "arguments": details?.arguments ?? [],
            "screen_bytes": capture.screen.utf8.count,
            "osc_bytes": capture.osc.utf8.count,
            "agent_id": jsonValue(result?.agentID),
            "display_name": jsonValue(result?.displayName),
            "source": jsonValue(result?.source?.rawValue),
            "source_path": jsonValue(result?.sourcePath),
            "process_matcher_id": jsonValue(result?.processMatcherID),
            "classification": result?.classification.rawValue ?? CmuxAgentClassification.unknown.rawValue,
            "state_rule_id": jsonValue(result?.stateRuleID),
            "matched_rule": jsonValue(result?.stateRuleID ?? result?.processMatcherID),
            "trace": (result?.trace ?? []).map { trace in
                [
                    "manifest_id": trace.manifestID,
                    "phase": trace.phase.rawValue,
                    "rule_id": trace.ruleID,
                    "condition_id": jsonValue(trace.conditionID),
                    "matched": trace.matched,
                    "detail": trace.detail,
                ]
            },
        ]
        if let error = manifestLoadError ?? registry.manifestLoadError {
            payload["manifest_error"] = error.localizedDescription
        }
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            let message = agentManifestError(
                key: "cli.agentManifests.error.encode",
                defaultValue: "Failed to encode agent manifest diagnostics."
            )
            return "ERROR: \(message)"
        }
        return "OK \(json)"
    }

    private nonisolated static func executablePath(for pid: Int) -> String? {
        guard pid > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid_t(pid), &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let path = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    private nonisolated static func jsonValue(_ value: Any?) -> Any {
        value ?? NSNull()
    }

    private nonisolated static func agentManifestError(
        key: StaticString,
        defaultValue: String.LocalizationValue
    ) -> String {
        String(localized: key, defaultValue: defaultValue)
    }
}
