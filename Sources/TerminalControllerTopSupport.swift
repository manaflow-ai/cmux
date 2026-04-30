import Foundation

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

    nonisolated func v2AnnotateTopWindows(
        _ windows: inout [[String: Any]],
        processSnapshot: CmuxTopProcessSnapshot,
        browserPIDOccurrences: [Int: Int],
        includeProcesses: Bool
    ) -> Set<Int> {
        var allPIDs: Set<Int> = []
        for index in windows.indices {
            var workspaces = windows[index]["workspaces"] as? [[String: Any]] ?? []
            var windowPIDs: Set<Int> = []
            for workspaceIndex in workspaces.indices {
                windowPIDs.formUnion(
                    v2AnnotateTopWorkspace(
                        &workspaces[workspaceIndex],
                        processSnapshot: processSnapshot,
                        browserPIDOccurrences: browserPIDOccurrences,
                        includeProcesses: includeProcesses
                    )
                )
            }
            windows[index]["workspaces"] = workspaces
            windows[index]["resources"] = processSnapshot.summaryPayload(for: windowPIDs)
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
        }
        workspace["tags"] = tags

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
        }
        pane["surfaces"] = surfaces
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

        if let ttyName = surface["tty"] as? String {
            let ttyPIDs = processSnapshot.pids(forTTYName: ttyName)
            surface["tty_process_pids"] = ttyPIDs.sorted()
            rootPIDs.formUnion(ttyPIDs)
            surfacePIDs.formUnion(processSnapshot.expandedPIDs(rootPIDs: ttyPIDs))
        } else {
            surface["tty_process_pids"] = []
        }

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
        }
        surface["webviews"] = webviews

        surface["root_pids"] = rootPIDs.sorted()
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
            webview["resources"] = processSnapshot.summaryPayload(for: [])
            webview["processes"] = []
            return []
        }

        let rootPIDs: Set<Int> = [pid]
        let pids = processSnapshot.expandedPIDs(rootPIDs: rootPIDs)
        webview["shared_process_count"] = browserPIDOccurrences[pid] ?? 1
        webview["root_pids"] = rootPIDs.sorted()
        webview["resources"] = processSnapshot.summaryPayload(for: pids, rootPIDs: rootPIDs)
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
            tag["resources"] = processSnapshot.summaryPayload(for: [])
            tag["processes"] = []
            return []
        }

        let rootPIDs: Set<Int> = [pid]
        let pids = processSnapshot.expandedPIDs(rootPIDs: rootPIDs)
        tag["root_pids"] = rootPIDs.sorted()
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
}
