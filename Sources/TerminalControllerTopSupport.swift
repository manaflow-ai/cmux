import Foundation
import Darwin

extension TerminalController {
    func v2TopTagIdentifier(workspaceId: UUID, key: String) -> String {
        "\(workspaceId.uuidString):tag:\(v2TopEscapedTagKey(key))"
    }

    func v2TopTagRef(workspaceId: UUID, key: String) -> String {
        "workspace:\(workspaceId.uuidString):tag:\(v2TopEscapedTagKey(key))"
    }

    func v2TopEscapedTagKey(_ key: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return key.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    nonisolated func v2TopBrowserPIDOccurrences(in windows: [[String: Any]]) -> [Int: Int] {
        var counts: [Int: Int] = [:]
        for window in windows {
            let workspaces = window["workspaces"] as? [[String: Any]] ?? []
            for workspace in workspaces {
                let panes = workspace["panes"] as? [[String: Any]] ?? []
                for pane in panes {
                    let surfaces = pane["surfaces"] as? [[String: Any]] ?? []
                    for surface in surfaces {
                        let webviews = surface["webviews"] as? [[String: Any]] ?? []
                        for webview in webviews {
                            guard let pid = v2TopInt(webview["pid"]) else { continue }
                            counts[pid, default: 0] += 1
                        }
                    }
                }
            }
        }
        return counts
    }

    nonisolated func v2TopMemoryDiagnosticPayload(
        processSnapshot: CmuxTopProcessSnapshot,
        annotatedWindows: [[String: Any]],
        topGroupLimit: Int = 12
    ) -> [String: Any] {
        let attributionByPID = v2TopMemoryAttributionByPID(in: annotatedWindows)
        return processSnapshot.memoryDiagnosticPayload(
            appPID: Int(Darwin.getpid()),
            topGroupLimit: topGroupLimit,
            attributionByPID: attributionByPID,
            unattributedTTYProcessIDs: v2TopUnattributedTTYProcessIDs(
                in: annotatedWindows,
                processSnapshot: processSnapshot,
                provenProcessIDs: Set(attributionByPID.keys)
            )
        )
    }

    nonisolated func v2AnnotateTopWindows(
        _ windows: inout [[String: Any]],
        processSnapshot: CmuxTopProcessSnapshot,
        browserPIDOccurrences: [Int: Int],
        includeProcesses: Bool
    ) -> Set<Int> {
        var allPIDs: Set<Int> = []
        for index in windows.indices {
            var workspaces = windows[index]["workspaces"] as? [[String: Any]] ?? []
            let appProcessPIDs = Set(v2TopIntArray(windows[index]["app_process_pids"]))
            var windowPIDs = appProcessPIDs
            var windowTopLevelPIDs: Set<Int> = []
            var windowForegroundProcessGroupIDs: Set<Int> = []
            for workspaceIndex in workspaces.indices {
                windowPIDs.formUnion(
                    v2AnnotateTopWorkspace(
                        &workspaces[workspaceIndex],
                        processSnapshot: processSnapshot,
                        browserPIDOccurrences: browserPIDOccurrences,
                        includeProcesses: includeProcesses
                    )
                )
                windowTopLevelPIDs.formUnion(v2TopIntArray(workspaces[workspaceIndex]["top_level_pids"]))
                windowForegroundProcessGroupIDs.formUnion(v2TopIntArray(workspaces[workspaceIndex]["foreground_pgids"]))
            }
            windows[index]["workspaces"] = workspaces
            windows[index]["app_process_pids"] = appProcessPIDs.sorted()
            windowTopLevelPIDs.formUnion(processSnapshot.topLevelPIDs(for: appProcessPIDs))
            windows[index]["top_level_pids"] = windowTopLevelPIDs.sorted()
            windows[index]["foreground_pgids"] = windowForegroundProcessGroupIDs.sorted()
            windows[index]["resources"] = processSnapshot.summaryPayload(for: windowPIDs, rootPIDs: appProcessPIDs)
            windows[index]["processes"] = includeProcesses
                ? processSnapshot.processTreePayload(for: appProcessPIDs, rootPIDs: appProcessPIDs)
                : []
            allPIDs.formUnion(windowPIDs)
        }
        return allPIDs
    }

    nonisolated func v2AnnotateTopWorkspace(
        _ workspace: inout [String: Any],
        processSnapshot: CmuxTopProcessSnapshot,
        browserPIDOccurrences: [Int: Int],
        includeProcesses: Bool
    ) -> Set<Int> {
        var workspacePIDs: Set<Int> = []
        var workspaceTopLevelPIDs: Set<Int> = []
        var workspaceForegroundProcessGroupIDs: Set<Int> = []

        var panes = workspace["panes"] as? [[String: Any]] ?? []
        for paneIndex in panes.indices {
            workspacePIDs.formUnion(
                v2AnnotateTopPane(
                    &panes[paneIndex],
                    processSnapshot: processSnapshot,
                    browserPIDOccurrences: browserPIDOccurrences,
                    includeProcesses: includeProcesses
                )
            )
            workspaceTopLevelPIDs.formUnion(v2TopIntArray(panes[paneIndex]["top_level_pids"]))
            workspaceForegroundProcessGroupIDs.formUnion(v2TopIntArray(panes[paneIndex]["foreground_pgids"]))
        }
        workspace["panes"] = panes

        var tags = workspace["tags"] as? [[String: Any]] ?? []
        for tagIndex in tags.indices {
            workspacePIDs.formUnion(
                v2AnnotateTopTag(
                    &tags[tagIndex],
                    processSnapshot: processSnapshot,
                    includeProcesses: includeProcesses
                )
            )
            workspaceTopLevelPIDs.formUnion(v2TopIntArray(tags[tagIndex]["top_level_pids"]))
            workspaceForegroundProcessGroupIDs.formUnion(v2TopIntArray(tags[tagIndex]["foreground_pgids"]))
        }
        workspace["tags"] = tags

        workspace["top_level_pids"] = workspaceTopLevelPIDs.sorted()
        workspace["foreground_pgids"] = workspaceForegroundProcessGroupIDs.sorted()
        workspace["resources"] = processSnapshot.summaryPayload(for: workspacePIDs)
        return workspacePIDs
    }

    nonisolated func v2AnnotateTopPane(
        _ pane: inout [String: Any],
        processSnapshot: CmuxTopProcessSnapshot,
        browserPIDOccurrences: [Int: Int],
        includeProcesses: Bool
    ) -> Set<Int> {
        var panePIDs: Set<Int> = []
        var paneTopLevelPIDs: Set<Int> = []
        var paneForegroundProcessGroupIDs: Set<Int> = []
        var surfaces = pane["surfaces"] as? [[String: Any]] ?? []
        for surfaceIndex in surfaces.indices {
            panePIDs.formUnion(
                v2AnnotateTopSurface(
                    &surfaces[surfaceIndex],
                    processSnapshot: processSnapshot,
                    browserPIDOccurrences: browserPIDOccurrences,
                    includeProcesses: includeProcesses
                )
            )
            paneTopLevelPIDs.formUnion(v2TopIntArray(surfaces[surfaceIndex]["top_level_pids"]))
            paneForegroundProcessGroupIDs.formUnion(v2TopIntArray(surfaces[surfaceIndex]["foreground_pgids"]))
        }
        pane["surfaces"] = surfaces
        pane["top_level_pids"] = paneTopLevelPIDs.sorted()
        pane["foreground_pgids"] = paneForegroundProcessGroupIDs.sorted()
        pane["resources"] = processSnapshot.summaryPayload(for: panePIDs)
        return panePIDs
    }

    nonisolated func v2AnnotateTopSurface(
        _ surface: inout [String: Any],
        processSnapshot: CmuxTopProcessSnapshot,
        browserPIDOccurrences: [Int: Int],
        includeProcesses: Bool
    ) -> Set<Int> {
        var rootPIDs: Set<Int> = []
        var surfacePIDs: Set<Int> = []

        let surfaceID = v2TopUUID(surface["id"])
        let ttyName = surface["tty"] as? String
        let ownership = processSnapshot.terminalProcessOwnership(
            surfaceID: surfaceID,
            ttyName: ttyName
        )

        surface["cmux_process_pids"] = ownership.explicitScopeProcessIDs.sorted()
        surface["tty_process_pids"] = ownership.observedTTYProcessIDs.sorted()
        surface["tty_owned_process_pids"] = ownership.ownedTTYProcessIDs.sorted()
        surface["tty_unattributed_process_pids"] = ownership.ambiguousTTYProcessIDs.sorted()
        surface["tty_process_ownership"] = ownership.payload()

        // A controlling TTY is evidence that a process was attached, not that
        // it is owned: PPID-1 processes can retain the TTY after reparenting.
        rootPIDs.formUnion(ownership.rootProcessIDs)
        surfacePIDs.formUnion(ownership.ownedProcessIDs)
        var processAttributionReasons = ownership.reasonByProcessID

        var webviews = surface["webviews"] as? [[String: Any]] ?? []
        for webviewIndex in webviews.indices {
            if let pid = v2TopInt(webviews[webviewIndex]["pid"]) {
                rootPIDs.insert(pid)
            }
            surfacePIDs.formUnion(
                v2AnnotateTopWebView(
                    &webviews[webviewIndex],
                    processSnapshot: processSnapshot,
                    browserPIDOccurrences: browserPIDOccurrences,
                    includeProcesses: includeProcesses
                )
            )
            if let pid = v2TopInt(webviews[webviewIndex]["pid"]) {
                processAttributionReasons[pid] = processAttributionReasons[pid]
                    ?? CmuxTopProcessOwnershipReason.webViewRoot.rawValue
            }
            if let webviewReasons = webviews[webviewIndex]["process_attribution_reasons"] as? [String: String] {
                for (rawPID, reason) in webviewReasons {
                    guard let pid = Int(rawPID) else { continue }
                    processAttributionReasons[pid] = processAttributionReasons[pid] ?? reason
                }
            }
        }
        surface["webviews"] = webviews

        surface["process_attribution_reasons"] = Dictionary(uniqueKeysWithValues: processAttributionReasons
            .sorted { $0.key < $1.key }
            .map { (String($0.key), $0.value) })
        surface["root_pids"] = rootPIDs.sorted()
        surface["top_level_pids"] = processSnapshot.topLevelPIDs(for: surfacePIDs).sorted()
        surface["foreground_pgids"] = processSnapshot.foregroundProcessGroupIDs(for: surfacePIDs).sorted()
        surface["resources"] = processSnapshot.summaryPayload(for: surfacePIDs, rootPIDs: rootPIDs)
        surface["processes"] = includeProcesses ? processSnapshot.processTreePayload(for: surfacePIDs, rootPIDs: rootPIDs) : []
        return surfacePIDs
    }

    nonisolated func v2AnnotateTopWebView(
        _ webview: inout [String: Any],
        processSnapshot: CmuxTopProcessSnapshot,
        browserPIDOccurrences: [Int: Int],
        includeProcesses: Bool
    ) -> Set<Int> {
        guard let pid = v2TopInt(webview["pid"]) else {
            webview["shared_process_count"] = NSNull()
            webview["root_pids"] = []
            webview["top_level_pids"] = []
            webview["foreground_pgids"] = []
            webview["resources"] = processSnapshot.summaryPayload(for: [])
            webview["process_attribution_reasons"] = [:]
            webview["processes"] = []
            return []
        }

        let rootPIDs: Set<Int> = [pid]
        let pids = processSnapshot.expandedPIDs(rootPIDs: rootPIDs)
        let sharedProcessCount = max(1, browserPIDOccurrences[pid] ?? 1)
        let resources = processSnapshot.summary(for: pids, rootPIDs: rootPIDs)
        webview["shared_process_count"] = sharedProcessCount
        webview["root_pids"] = rootPIDs.sorted()
        webview["top_level_pids"] = processSnapshot.topLevelPIDs(for: pids).sorted()
        webview["foreground_pgids"] = processSnapshot.foregroundProcessGroupIDs(for: pids).sorted()
        webview["resources"] = resources.attributedPayload(sharedAcross: sharedProcessCount)
        webview["process_attribution_reasons"] = v2TopProcessAttributionReasons(
            for: pids,
            rootPIDs: rootPIDs,
            processSnapshot: processSnapshot,
            rootReason: CmuxTopProcessOwnershipReason.webViewRoot.rawValue
        )
        webview["processes"] = includeProcesses ? processSnapshot.processTreePayload(for: pids, rootPIDs: rootPIDs) : []
        return pids
    }

    nonisolated func v2AnnotateTopTag(
        _ tag: inout [String: Any],
        processSnapshot: CmuxTopProcessSnapshot,
        includeProcesses: Bool
    ) -> Set<Int> {
        guard let pid = v2TopInt(tag["pid"]) else {
            tag["root_pids"] = []
            tag["top_level_pids"] = []
            tag["foreground_pgids"] = []
            tag["resources"] = processSnapshot.summaryPayload(for: [])
            tag["processes"] = []
            return []
        }

        let rootPIDs: Set<Int> = [pid]
        let pids = processSnapshot.expandedPIDs(rootPIDs: rootPIDs)
        tag["root_pids"] = rootPIDs.sorted()
        tag["top_level_pids"] = processSnapshot.topLevelPIDs(for: pids).sorted()
        tag["foreground_pgids"] = processSnapshot.foregroundProcessGroupIDs(for: pids).sorted()
        tag["resources"] = processSnapshot.summaryPayload(for: pids, rootPIDs: rootPIDs)
        tag["processes"] = includeProcesses ? processSnapshot.processTreePayload(for: pids, rootPIDs: rootPIDs) : []
        return pids
    }

    nonisolated func v2TopInt(_ raw: Any?) -> Int? {
        if let value = raw as? Int {
            return value
        }
        if let value = raw as? NSNumber {
            return value.intValue
        }
        if let value = raw as? String {
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    nonisolated func v2TopIntArray(_ raw: Any?) -> [Int] {
        if let values = raw as? [Int] {
            return values
        }
        guard let values = raw as? [Any] else { return [] }
        return values.compactMap(v2TopInt)
    }

    nonisolated func v2TopString(_ raw: Any?) -> String? {
        guard let value = raw as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    nonisolated func v2TopUUID(_ raw: Any?) -> UUID? {
        if let value = raw as? UUID {
            return value
        }
        if let value = raw as? String {
            return UUID(uuidString: value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    nonisolated func v2AttachTopApplicationProcess(
        to windows: inout [[String: Any]],
        workspaceFilter: UUID? = nil
    ) {
        guard workspaceFilter == nil else {
            for index in windows.indices {
                windows[index]["app_process_pids"] = []
            }
            return
        }
        guard let firstIndex = windows.indices.first else { return }

        let appProcessID = Int(Darwin.getpid())
        let targetIndex = windows.indices.first { index in
            if let isKeyWindow = windows[index]["key"] as? Bool {
                return isKeyWindow
            }
            if let isKeyWindow = windows[index]["key"] as? NSNumber {
                return isKeyWindow.boolValue
            }
            return false
        } ?? firstIndex

        windows[targetIndex]["app_process_pids"] = [appProcessID]
        for index in windows.indices where index != targetIndex {
            windows[index]["app_process_pids"] = []
        }
    }

}
