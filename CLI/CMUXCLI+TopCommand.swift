import Foundation
import CMUXAgentLaunch
import CmuxFoundation
import CmuxSocketControl
import CoreFoundation
import CryptoKit
import Darwin
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
#if canImport(Security)
import Security
#endif
#if canImport(Sentry)
import Sentry
#endif


// MARK: - cmux top command
extension CMUXCLI {
    private struct TopCommandOptions {
        let includeAllWindows: Bool
        let workspaceHandle: String?
        let windowHandle: String?
        let jsonOutput: Bool
        let showProcesses: Bool
        let sortKey: TopSortKey?
        let textFormat: TopTextFormat
        let requestedFlatOutput: Bool
        let requestedFormat: Bool
    }

    func runTopCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let options = try parseTopCommandOptions(commandArgs)
        let structuredOutput = jsonOutput || options.jsonOutput
        if structuredOutput, options.sortKey != nil {
            throw CLIError(message: "top: --sort is only supported for text output; use --json to sort structured data externally")
        }
        if structuredOutput, options.requestedFlatOutput || options.requestedFormat {
            throw CLIError(message: "top: --flat and --format are only supported for text output")
        }
        let payload = try buildTopPayload(options: options, client: client)
        if structuredOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
        } else {
            switch options.textFormat {
            case .tree:
                print(renderTopText(
                    payload: payload,
                    idFormat: idFormat,
                    showProcesses: options.showProcesses,
                    sortKey: options.sortKey
                ))
            case .tsv:
                print(renderTopFlatTSV(
                    payload: payload,
                    idFormat: idFormat,
                    showProcesses: options.showProcesses,
                    sortKey: options.sortKey
                ))
            }
        }
    }

    private func parseTopCommandOptions(_ args: [String]) throws -> TopCommandOptions {
        let (workspaceOpt, rem0) = parseOption(args, name: "--workspace")
        if rem0.contains("--workspace") {
            throw CLIError(message: "top requires --workspace <id|ref|index>")
        }
        let (windowOpt, rem1) = parseOption(rem0, name: "--window")
        if rem1.contains("--window") {
            throw CLIError(message: "top requires --window <id|ref|index>")
        }
        let (sortOpt, rem2) = parseOption(rem1, name: "--sort")
        if rem2.contains("--sort") {
            throw CLIError(message: "top requires --sort <cpu|mem|proc>")
        }
        let (formatOpt, rem3) = parseOption(rem2, name: "--format")
        if rem3.contains("--format") {
            throw CLIError(message: "top requires --format <tree|tsv>")
        }

        var includeAll = false
        var jsonOutput = false
        var showProcesses = false
        var flatOutput = false
        var remaining: [String] = []
        for arg in rem3 {
            if arg == "--all" {
                includeAll = true
                continue
            }
            if arg == "--json" {
                jsonOutput = true
                continue
            }
            if arg == "--processes" {
                showProcesses = true
                continue
            }
            if arg == "--flat" {
                flatOutput = true
                continue
            }
            remaining.append(arg)
        }

        if let unknown = remaining.first(where: { $0.hasPrefix("--") }) {
            throw CLIError(message: "top: unknown flag '\(unknown)'. Known flags: --all --workspace <id|ref|index> --window <id|ref|index> --processes --sort <cpu|mem|proc> --flat --format <tree|tsv> --json")
        }
        if let extra = remaining.first {
            throw CLIError(message: "top: unexpected argument '\(extra)'")
        }
        let format = try parseTopTextFormat(formatOpt)
        if flatOutput, format == .tree {
            throw CLIError(message: "top: --flat requires --format tsv or no --format")
        }

        return TopCommandOptions(
            includeAllWindows: includeAll,
            workspaceHandle: workspaceOpt,
            windowHandle: windowOpt,
            jsonOutput: jsonOutput,
            showProcesses: showProcesses,
            sortKey: try parseTopSortKey(sortOpt),
            textFormat: format ?? (flatOutput ? .tsv : .tree),
            requestedFlatOutput: flatOutput,
            requestedFormat: formatOpt != nil
        )
    }

    private func parseTopSortKey(_ raw: String?) throws -> TopSortKey? {
        guard let raw else { return nil }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "cpu", "cpu%":
            return .cpu
        case "rss", "mem", "memory", "ram":
            return .memory
        case "proc", "process", "processes", "count":
            return .proc
        default:
            throw CLIError(message: "top: invalid --sort value '\(raw)'. Use cpu, mem, or proc")
        }
    }

    private func parseTopTextFormat(_ raw: String?) throws -> TopTextFormat? {
        guard let raw else { return nil }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "tree":
            return .tree
        case "tsv", "tab", "tabs":
            return .tsv
        default:
            throw CLIError(message: "top: invalid --format value '\(raw)'. Use tree or tsv")
        }
    }

    private func buildTopPayload(
        options: TopCommandOptions,
        client: SocketClient,
        responseTimeout: TimeInterval? = nil
    ) throws -> [String: Any] {
        var params: [String: Any] = [
            "all_windows": options.includeAllWindows,
            "include_processes": options.showProcesses
        ]
        let windowHandle = try normalizeWindowHandle(options.windowHandle, client: client)
        if options.includeAllWindows, windowHandle != nil {
            throw CLIError(message: "top: --window cannot be combined with --all")
        }
        if let windowHandle {
            params["window_id"] = windowHandle
        }
        if let workspaceRaw = options.workspaceHandle {
            guard let workspaceHandle = try normalizeWorkspaceHandle(workspaceRaw, client: client, windowHandle: windowHandle) else {
                throw CLIError(message: String(format: String(
                    localized: "cli.top.error.invalidWorkspace",
                    defaultValue: "top: invalid workspace handle '%@'"
                ), workspaceRaw))
            }
            params["workspace_id"] = workspaceHandle
        }
        if let caller = treeCallerContextFromEnvironment() {
            params["caller"] = caller
        }

        do {
            return try client.sendV2(method: "system.top", params: params, responseTimeout: responseTimeout)
        } catch let error as CLIError where error.message.hasPrefix("method_not_found:") {
            throw CLIError(message: String(localized: "cli.top.error.processDiagnosticsUnsupported", defaultValue: "cmux top requires a running cmux build that supports process diagnostics"))
        }
    }

    private func renderTopText(
        payload: [String: Any],
        idFormat: CLIIDFormat,
        showProcesses: Bool,
        sortKey: TopSortKey? = nil
    ) -> String {
        let windows = payload["windows"] as? [[String: Any]] ?? []
        guard !windows.isEmpty else { return "No windows" }

        var lines: [String] = ["  CPU%    MEMORY  PROC  NODE"]
        if let totals = payload["totals"] as? [String: Any] {
            lines.append("\(topResourceColumns(resources: totals))total")
        }

        for window in topSortedItems(windows, sortKey: sortKey, node: { $0 }) {
            lines.append("\(topResourceColumns(node: window))\(topWindowLabel(window, idFormat: idFormat))")

            let windowProcesses = showProcesses ? (window["processes"] as? [[String: Any]] ?? []) : []
            let workspaces = window["workspaces"] as? [[String: Any]] ?? []
            let windowChildren = topSortedItems(
                windowProcesses.map { TopWindowChild.process($0) } + workspaces.map { TopWindowChild.workspace($0) },
                sortKey: sortKey,
                node: { $0.node }
            )
            for (windowChildIndex, windowChild) in windowChildren.enumerated() {
                let windowChildIsLast = windowChildIndex == windowChildren.count - 1
                let windowChildBranch = windowChildIsLast ? "└── " : "├── "
                let windowChildIndent = windowChildIsLast ? "    " : "│   "

                switch windowChild {
                case .process(let process):
                    lines.append("\(topResourceColumns(node: process))\(windowChildBranch)\(topProcessLabel(process))")
                    appendTopProcessLines(
                        process["children"] as? [[String: Any]] ?? [],
                        to: &lines,
                        indent: windowChildIndent,
                        sortKey: sortKey
                    )
                case .workspace(let workspace):
                    lines.append("\(topResourceColumns(node: workspace))\(windowChildBranch)\(topWorkspaceLabel(workspace, idFormat: idFormat))")

                    let tags = workspace["tags"] as? [[String: Any]] ?? []
                    let panes = workspace["panes"] as? [[String: Any]] ?? []
                    let workspaceChildren = topSortedItems(
                        tags.map { TopWorkspaceChild.tag($0) } + panes.map { TopWorkspaceChild.pane($0) },
                        sortKey: sortKey,
                        node: { $0.node }
                    )

                    for (workspaceChildIndex, workspaceChild) in workspaceChildren.enumerated() {
                        let childIsLast = workspaceChildIndex == workspaceChildren.count - 1
                        switch workspaceChild {
                        case .tag(let tag):
                            let tagIsLast = childIsLast
                            let tagBranch = tagIsLast ? "└── " : "├── "
                            let tagIndent = tagIsLast ? "    " : "│   "
                            lines.append("\(topResourceColumns(node: tag))\(windowChildIndent)\(tagBranch)\(topTagLabel(tag))")
                            if showProcesses {
                                appendTopProcessLines(
                                    tag["processes"] as? [[String: Any]] ?? [],
                                    to: &lines,
                                    indent: windowChildIndent + tagIndent,
                                    sortKey: sortKey
                                )
                            }
                        case .pane(let pane):
                            let paneIsLast = childIsLast
                            let paneBranch = paneIsLast ? "└── " : "├── "
                            let paneIndent = paneIsLast ? "    " : "│   "
                            lines.append("\(topResourceColumns(node: pane))\(windowChildIndent)\(paneBranch)\(topPaneLabel(pane, idFormat: idFormat))")

                            let surfaces = topSortedItems(pane["surfaces"] as? [[String: Any]] ?? [], sortKey: sortKey, node: { $0 })
                            for (surfaceIndex, surface) in surfaces.enumerated() {
                                let surfaceIsLast = surfaceIndex == surfaces.count - 1
                                let surfaceBranch = surfaceIsLast ? "└── " : "├── "
                                let surfaceIndent = surfaceIsLast ? "    " : "│   "
                                lines.append("\(topResourceColumns(node: surface))\(windowChildIndent)\(paneIndent)\(surfaceBranch)\(topSurfaceLabel(surface, idFormat: idFormat))")

                                let webviews = surface["webviews"] as? [[String: Any]] ?? []
                                let surfaceProcesses = showProcesses ? (surface["processes"] as? [[String: Any]] ?? []) : []
                                let surfaceChildren = topSortedItems(
                                    webviews.map { TopSurfaceChild.webview($0) } + surfaceProcesses.map { TopSurfaceChild.process($0) },
                                    sortKey: sortKey,
                                    node: { $0.node }
                                )
                                for (surfaceChildIndex, surfaceChild) in surfaceChildren.enumerated() {
                                    let surfaceChildIsLast = surfaceChildIndex == surfaceChildren.count - 1
                                    let surfaceChildBranch = surfaceChildIsLast ? "└── " : "├── "
                                    let surfaceChildIndent = surfaceChildIsLast ? "    " : "│   "

                                    switch surfaceChild {
                                    case .webview(let webview):
                                        lines.append("\(topResourceColumns(node: webview))\(windowChildIndent)\(paneIndent)\(surfaceIndent)\(surfaceChildBranch)\(topWebViewLabel(webview))")
                                        if showProcesses {
                                            appendTopProcessLines(
                                                webview["processes"] as? [[String: Any]] ?? [],
                                                to: &lines,
                                                indent: windowChildIndent + paneIndent + surfaceIndent + surfaceChildIndent,
                                                sortKey: sortKey
                                            )
                                        }
                                    case .process(let process):
                                        appendTopProcessLine(
                                            process,
                                            to: &lines,
                                            indent: windowChildIndent + paneIndent + surfaceIndent,
                                            branch: surfaceChildBranch,
                                            childIndent: surfaceChildIndent,
                                            sortKey: sortKey
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        return lines.joined(separator: "\n")
    }

    private enum TopWindowChild {
        case process([String: Any])
        case workspace([String: Any])

        var node: [String: Any] {
            switch self {
            case .process(let node), .workspace(let node):
                return node
            }
        }
    }

    private enum TopWorkspaceChild {
        case tag([String: Any])
        case pane([String: Any])

        var node: [String: Any] {
            switch self {
            case .tag(let node), .pane(let node):
                return node
            }
        }
    }

    private enum TopSurfaceChild {
        case webview([String: Any])
        case process([String: Any])

        var node: [String: Any] {
            switch self {
            case .webview(let node), .process(let node):
                return node
            }
        }
    }

    private func topSortedItems<T>(
        _ items: [T],
        sortKey: TopSortKey?,
        node: (T) -> [String: Any]
    ) -> [T] {
        guard let sortKey else { return items }
        return items.enumerated().sorted { lhs, rhs in
            let lhsValue = topSortValue(node(lhs.element), sortKey: sortKey)
            let rhsValue = topSortValue(node(rhs.element), sortKey: sortKey)
            guard lhsValue != rhsValue else { return lhs.offset < rhs.offset }
            return lhsValue > rhsValue
        }.map(\.element)
    }

    private func topSortValue(_ node: [String: Any], sortKey: TopSortKey) -> Double {
        let resources = node["resources"] as? [String: Any] ?? [:]
        switch sortKey {
        case .cpu:
            let value = topDouble(resources["cpu_percent"])
            return value.isFinite ? value : 0
        case .memory:
            return Double(topMemoryBytes(resources))
        case .proc:
            return Double(topInt(resources["process_count"]) ?? 0)
        }
    }

    private struct TopFlatRow {
        let resources: [String: Any]
        let kind: String
        let ref: String
        let parentRef: String
        let title: String
        let ordinal: Int
    }

    private func renderTopFlatTSV(
        payload: [String: Any],
        idFormat: CLIIDFormat,
        showProcesses: Bool,
        sortKey: TopSortKey? = nil
    ) -> String {
        let windows = payload["windows"] as? [[String: Any]] ?? []
        guard !windows.isEmpty else { return "" }

        var rows: [TopFlatRow] = []
        var ordinal = 0
        if let totals = payload["totals"] as? [String: Any] {
            appendTopFlatRow(
                resources: totals,
                kind: "total",
                ref: "total",
                parentRef: "",
                title: "",
                ordinal: &ordinal,
                to: &rows
            )
        }

        for window in topSortedItems(windows, sortKey: sortKey, node: { $0 }) {
            let windowRef = topFlatHandle(window, fallback: "window", idFormat: idFormat)
            appendTopFlatNode(
                window,
                kind: "window",
                ref: windowRef,
                parentRef: "total",
                title: "",
                ordinal: &ordinal,
                to: &rows
            )

            let windowProcesses = showProcesses ? (window["processes"] as? [[String: Any]] ?? []) : []
            let workspaces = window["workspaces"] as? [[String: Any]] ?? []
            let windowChildren = topSortedItems(
                windowProcesses.map { TopWindowChild.process($0) } + workspaces.map { TopWindowChild.workspace($0) },
                sortKey: sortKey,
                node: { $0.node }
            )
            for windowChild in windowChildren {
                switch windowChild {
                case .process(let process):
                    appendTopFlatProcesses(
                        [process],
                        parentRef: windowRef,
                        ordinal: &ordinal,
                        to: &rows,
                        sortKey: sortKey
                    )
                case .workspace(let workspace):
                    let workspaceRef = topFlatHandle(workspace, fallback: "workspace", idFormat: idFormat)
                    appendTopFlatNode(
                        workspace,
                        kind: "workspace",
                        ref: workspaceRef,
                        parentRef: windowRef,
                        title: workspace["title"] as? String ?? "",
                        ordinal: &ordinal,
                        to: &rows
                    )

                    let tags = workspace["tags"] as? [[String: Any]] ?? []
                    let panes = workspace["panes"] as? [[String: Any]] ?? []
                    let workspaceChildren = topSortedItems(
                        tags.map { TopWorkspaceChild.tag($0) } + panes.map { TopWorkspaceChild.pane($0) },
                        sortKey: sortKey,
                        node: { $0.node }
                    )
                    for workspaceChild in workspaceChildren {
                        switch workspaceChild {
                        case .tag(let tag):
                            let tagRef = topFlatHandle(tag, fallback: topLabelText(tag["key"] as? String), idFormat: idFormat)
                            appendTopFlatNode(
                                tag,
                                kind: "tag",
                                ref: tagRef,
                                parentRef: workspaceRef,
                                title: tag["value"] as? String ?? "",
                                ordinal: &ordinal,
                                to: &rows
                            )
                            if showProcesses {
                                appendTopFlatProcesses(
                                    tag["processes"] as? [[String: Any]] ?? [],
                                    parentRef: tagRef,
                                    ordinal: &ordinal,
                                    to: &rows,
                                    sortKey: sortKey
                                )
                            }
                        case .pane(let pane):
                            let paneRef = topFlatHandle(pane, fallback: "pane", idFormat: idFormat)
                            appendTopFlatNode(
                                pane,
                                kind: "pane",
                                ref: paneRef,
                                parentRef: workspaceRef,
                                title: "",
                                ordinal: &ordinal,
                                to: &rows
                            )

                            let surfaces = topSortedItems(pane["surfaces"] as? [[String: Any]] ?? [], sortKey: sortKey, node: { $0 })
                            for surface in surfaces {
                                let surfaceRef = topFlatHandle(surface, fallback: "surface", idFormat: idFormat)
                                appendTopFlatNode(
                                    surface,
                                    kind: "surface",
                                    ref: surfaceRef,
                                    parentRef: paneRef,
                                    title: surface["title"] as? String ?? "",
                                    ordinal: &ordinal,
                                    to: &rows
                                )

                                let webviews = surface["webviews"] as? [[String: Any]] ?? []
                                let surfaceProcesses = showProcesses ? (surface["processes"] as? [[String: Any]] ?? []) : []
                                let surfaceChildren = topSortedItems(
                                    webviews.map { TopSurfaceChild.webview($0) } + surfaceProcesses.map { TopSurfaceChild.process($0) },
                                    sortKey: sortKey,
                                    node: { $0.node }
                                )
                                for surfaceChild in surfaceChildren {
                                    switch surfaceChild {
                                    case .webview(let webview):
                                        let fallback = topInt(webview["pid"]).map { "pid:\($0)" } ?? "webview"
                                        let webviewRef = topFlatHandle(webview, fallback: fallback, idFormat: idFormat)
                                        appendTopFlatNode(
                                            webview,
                                            kind: "webview",
                                            ref: webviewRef,
                                            parentRef: surfaceRef,
                                            title: webview["title"] as? String ?? "",
                                            ordinal: &ordinal,
                                            to: &rows
                                        )
                                        if showProcesses {
                                            appendTopFlatProcesses(
                                                webview["processes"] as? [[String: Any]] ?? [],
                                                parentRef: webviewRef,
                                                ordinal: &ordinal,
                                                to: &rows,
                                                sortKey: sortKey
                                            )
                                        }
                                    case .process(let process):
                                        appendTopFlatProcesses(
                                            [process],
                                            parentRef: surfaceRef,
                                            ordinal: &ordinal,
                                            to: &rows,
                                            sortKey: sortKey
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        return rows.map(topFlatTSVLine).joined(separator: "\n")
    }

    private func appendTopFlatNode(
        _ node: [String: Any],
        kind: String,
        ref: String,
        parentRef: String,
        title: String,
        ordinal: inout Int,
        to rows: inout [TopFlatRow]
    ) {
        appendTopFlatRow(
            resources: node["resources"] as? [String: Any] ?? [:],
            kind: kind,
            ref: ref,
            parentRef: parentRef,
            title: title,
            ordinal: &ordinal,
            to: &rows
        )
    }

    private func appendTopFlatProcesses(
        _ processes: [[String: Any]],
        parentRef: String,
        ordinal: inout Int,
        to rows: inout [TopFlatRow],
        sortKey: TopSortKey?
    ) {
        for process in topSortedItems(processes, sortKey: sortKey, node: { $0 }) {
            let processRef = topInt(process["pid"]).map(String.init)
                ?? topFlatHandle(process, fallback: "process", idFormat: .refs)
            appendTopFlatNode(
                process,
                kind: "process",
                ref: processRef,
                parentRef: parentRef,
                title: process["name"] as? String ?? "",
                ordinal: &ordinal,
                to: &rows
            )
            appendTopFlatProcesses(
                process["children"] as? [[String: Any]] ?? [],
                parentRef: processRef,
                ordinal: &ordinal,
                to: &rows,
                sortKey: sortKey
            )
        }
    }

    private func appendTopFlatRow(
        resources: [String: Any],
        kind: String,
        ref: String,
        parentRef: String,
        title: String,
        ordinal: inout Int,
        to rows: inout [TopFlatRow]
    ) {
        rows.append(TopFlatRow(
            resources: resources,
            kind: kind,
            ref: ref,
            parentRef: parentRef,
            title: title,
            ordinal: ordinal
        ))
        ordinal += 1
    }

    private func topFlatHandle(_ node: [String: Any], fallback: String, idFormat: CLIIDFormat) -> String {
        let handle = topLabelText(textHandle(node, idFormat: idFormat))
        if handle != "?" {
            return handle
        }
        let sanitizedFallback = topLabelText(fallback)
        return sanitizedFallback.isEmpty ? "unknown" : sanitizedFallback
    }

    private func topFlatTSVLine(_ row: TopFlatRow) -> String {
        [
            topFlatCPU(row.resources),
            String(topMemoryBytes(row.resources)),
            String(topInt(row.resources["process_count"]) ?? 0),
            topTSVField(row.kind),
            topTSVField(row.ref),
            topTSVField(row.parentRef),
            topTSVField(row.title),
        ].joined(separator: "\t")
    }

    private func topFlatCPU(_ resources: [String: Any]) -> String {
        let value = topDouble(resources["cpu_percent"])
        guard value.isFinite else { return "0.0" }
        return String(format: "%.1f", value)
    }

    private func topTSVField(_ raw: String) -> String {
        topLabelText(raw)
    }

    private func appendTopProcessLines(
        _ processes: [[String: Any]],
        to lines: inout [String],
        indent: String,
        sortKey: TopSortKey?
    ) {
        let sortedProcesses = topSortedItems(processes, sortKey: sortKey, node: { $0 })
        for (index, process) in sortedProcesses.enumerated() {
            let isLast = index == sortedProcesses.count - 1
            let branch = isLast ? "└── " : "├── "
            let childIndent = isLast ? "    " : "│   "
            appendTopProcessLine(
                process,
                to: &lines,
                indent: indent,
                branch: branch,
                childIndent: childIndent,
                sortKey: sortKey
            )
        }
    }

    private func appendTopProcessLine(
        _ process: [String: Any],
        to lines: inout [String],
        indent: String,
        branch: String,
        childIndent: String,
        sortKey: TopSortKey?
    ) {
        lines.append("\(topResourceColumns(node: process))\(indent)\(branch)\(topProcessLabel(process))")
        appendTopProcessLines(
            process["children"] as? [[String: Any]] ?? [],
            to: &lines,
            indent: indent + childIndent,
            sortKey: sortKey
        )
    }

    private func topWindowLabel(_ window: [String: Any], idFormat: CLIIDFormat) -> String {
        var parts = ["window \(textHandle(window, idFormat: idFormat))"]
        if (window["key"] as? Bool) == true {
            parts.append("[key]")
        }
        if (window["visible"] as? Bool) == false {
            parts.append("[hidden]")
        }
        return parts.joined(separator: " ")
    }

    private func topWorkspaceLabel(_ workspace: [String: Any], idFormat: CLIIDFormat) -> String {
        var parts = ["workspace \(textHandle(workspace, idFormat: idFormat))"]
        let title = topLabelText(workspace["title"] as? String)
        if !title.isEmpty {
            parts.append("\"\(title)\"")
        }
        if (workspace["selected"] as? Bool) == true {
            parts.append("[selected]")
        }
        if (workspace["pinned"] as? Bool) == true {
            parts.append("[pinned]")
        }
        return parts.joined(separator: " ")
    }

    private func topPaneLabel(_ pane: [String: Any], idFormat: CLIIDFormat) -> String {
        var parts = ["pane \(textHandle(pane, idFormat: idFormat))"]
        if (pane["focused"] as? Bool) == true {
            parts.append("[focused]")
        }
        return parts.joined(separator: " ")
    }

    private func topSurfaceLabel(_ surface: [String: Any], idFormat: CLIIDFormat) -> String {
        let rawType = topLabelText(surface["type"] as? String)
        let surfaceType = rawType.isEmpty ? "unknown" : rawType
        var parts = ["surface \(textHandle(surface, idFormat: idFormat))", "[\(surfaceType)]"]
        let title = topLabelText(surface["title"] as? String)
        if !title.isEmpty {
            parts.append("\"\(title)\"")
        }
        if (surface["selected"] as? Bool) == true {
            parts.append("[selected]")
        }
        let tty = topLabelText(surface["tty"] as? String)
        if !tty.isEmpty {
            parts.append("tty=\(tty)")
        }
        if let pid = topInt(surface["browser_web_content_pid"]) {
            parts.append("webpid=\(pid)")
        }
        let url = topLabelText(surface["url"] as? String)
        if surfaceType.lowercased() == "browser", !url.isEmpty {
            parts.append(url)
        }
        return parts.joined(separator: " ")
    }

    private func topTagLabel(_ tag: [String: Any]) -> String {
        let key = topLabelText(tag["key"] as? String)
        let value = topLabelText(tag["value"] as? String)
        var parts = ["tag \(key.isEmpty ? "unknown" : key)"]
        if !value.isEmpty {
            parts.append("\"\(value)\"")
        }
        if (tag["visible"] as? Bool) == false {
            parts.append("[pid-only]")
        }
        if let pid = topInt(tag["pid"]) {
            parts.append("pid=\(pid)")
        }
        return parts.joined(separator: " ")
    }

    private func topWebViewLabel(_ webview: [String: Any]) -> String {
        var parts = ["webview"]
        if let pid = topInt(webview["pid"]) {
            parts.append("pid=\(pid)")
        } else {
            parts.append("pid=unknown")
        }
        if let sharedCount = topInt(webview["shared_process_count"]), sharedCount > 1 {
            parts.append("[shared x\(sharedCount)]")
        }
        let title = topLabelText(webview["title"] as? String)
        if !title.isEmpty {
            parts.append("\"\(title)\"")
        }
        let url = topLabelText(webview["url"] as? String)
        if !url.isEmpty {
            parts.append(url)
        }
        return parts.joined(separator: " ")
    }

    private func topProcessLabel(_ process: [String: Any]) -> String {
        let pid = topInt(process["pid"]).map(String.init) ?? "?"
        let name = topLabelText(process["name"] as? String)
        let label = name.isEmpty ? "process" : name
        var parts = ["process", pid, label]
        let attributionReason = topLabelText(process["attribution_reason"] as? String)
        if !attributionReason.isEmpty {
            parts.append("[\(attributionReason)]")
        }
        return parts.joined(separator: " ")
    }

    private func topResourceColumns(node: [String: Any]) -> String {
        topResourceColumns(resources: node["resources"] as? [String: Any] ?? [:])
    }

    private func topResourceColumns(resources: [String: Any]) -> String {
        let cpu = topDouble(resources["cpu_percent"])
        let memory = topMemoryBytes(resources)
        let count = topInt(resources["process_count"]) ?? 0
        let cpuText = String(format: "%6.1f%%", cpu)
        let memoryText = padLeft(formatBytes(memory), width: 9)
        let countText = padLeft(String(count), width: 5)
        return "\(cpuText) \(memoryText) \(countText)  "
    }

    private func topMemoryBytes(_ resources: [String: Any]) -> Int64 {
        if resources["memory_bytes"] != nil {
            return topInt64(resources["memory_bytes"])
        }
        return topInt64(resources["resident_bytes"])
    }

    func formatBytes(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(max(0, bytes))
        var unitIndex = 0
        while value >= 1024, unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }
        if unitIndex == 0 {
            return "\(Int(value)) \(units[unitIndex])"
        }
        return String(format: "%.1f %@", value, units[unitIndex])
    }

    func padLeft(_ value: String, width: Int) -> String {
        guard value.count < width else { return value }
        return String(repeating: " ", count: width - value.count) + value
    }

    func topInt(_ raw: Any?) -> Int? {
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

    func topInt64(_ raw: Any?) -> Int64 {
        if let value = raw as? Int64 {
            return value
        }
        if let value = raw as? Int {
            return Int64(value)
        }
        if let value = raw as? NSNumber {
            return value.int64Value
        }
        if let value = raw as? String,
           let parsed = Int64(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return parsed
        }
        return 0
    }

    private func topDouble(_ raw: Any?) -> Double {
        if let value = raw as? Double {
            return value
        }
        if let value = raw as? NSNumber {
            return value.doubleValue
        }
        if let value = raw as? String,
           let parsed = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return parsed
        }
        return 0
    }

    func isUUID(_ value: String) -> Bool {
        return UUID(uuidString: value) != nil
    }

}
