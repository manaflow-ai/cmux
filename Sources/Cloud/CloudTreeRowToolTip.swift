import CmuxCloud
import CmuxSurfaceCatalogModel
import CmuxWorkspacePresence
import Foundation

enum CloudTreeRowToolTip {
    /// Hover text and accessibility label for `node`, including the presence
    /// heads the cell resolved for a workspace row.
    @MainActor
    static func describe(
        node: CloudTreeNode,
        style: CloudTreeStyle,
        presenceHeads: [WorkspacePresenceParticipant]
    ) -> CloudTreeRowDescription {
        switch node.kind {
        case .machine(let machine, _):
            let content = CloudTreeMachineRowContent(machine: machine, style: style, resources: node.resourceSection)
            return .init(toolTip: content.toolTip, accessibilityLabel: content.accessibilityLabel)
        case .pendingMachine(let operation):
            // The failure's first line rides along so a red row explains itself on hover.
            return .init(toolTip: operation.summaryLine, accessibilityLabel: node.searchableTitle)
        case .localMachine(let row):
            return .init(toolTip: row.name, accessibilityLabel: node.searchableTitle)
        case .device(let row):
            // Full status and counts: the row itself carries only a dim fact.
            let content = CloudTreeDeviceRowContent(row: row, style: style)
            return .init(toolTip: content.toolTip, accessibilityLabel: content.accessibilityLabel)
        case .workspace(_, let workspace, let terminalCount, _, _):
            let lines = workspaceLines(workspace, terminalCount: terminalCount, presenceHeads: presenceHeads)
            let names = WorkspacePresencePolicy.accessibilityLabel(presenceHeads)
            return .init(
                toolTip: joined(lines, beyond: node.searchableTitle),
                accessibilityLabel: presenceHeads.isEmpty
                    ? node.searchableTitle
                    : "\(node.searchableTitle), \(names)"
            )
        case .localWorkspace(let row):
            return .init(
                toolTip: joined([row.title], beyond: node.searchableTitle),
                accessibilityLabel: node.searchableTitle
            )
        case .terminal(let row):
            let content = CloudTreeTerminalRowContent(row: row, style: style)
            return .init(
                toolTip: content.toolTip.isEmpty ? nil : content.toolTip,
                accessibilityLabel: content.accessibilityLabel
            )
        case .display(let resource, _, _):
            // `searchableTitle` already resolves the remote view name, the
            // resource title and the "Desktop" fallback in that order.
            //
            // No `beyond:` here, unlike the browser and port cases: `text(for:)`
            // always returns at least the transport ("noVNC"), so a display's
            // hover text can never reduce to the title the row drew.
            let detail = CloudTreeRowContentView.text(for: resource)
            return .init(
                toolTip: joined([node.searchableTitle, detail]),
                accessibilityLabel: [node.searchableTitle, detail].joined(separator: ", ")
            )
        case .browser(let row):
            // `searchableTitle` resolves the rename, then the page title, then
            // the "browser" fallback, which is exactly what the row draws.
            // Reading `resource.title` here instead would ignore a rename and
            // keep drifting every time the page navigates.
            let title = node.searchableTitle
            return .init(
                toolTip: joined([title, row.resource.url, CloudTreeBrowserDetail.text(for: row)], beyond: title),
                accessibilityLabel: title
            )
        case .port(let resource, _, _):
            let presentation = CloudTreePortPresentation(resource: resource)
            return .init(
                toolTip: presentation.toolTip,
                accessibilityLabel: presentation.accessibilityLabel
            )
        case .resource(_, let row):
            return .init(
                toolTip: joined([row.accessibilityLabel], beyond: node.searchableTitle),
                accessibilityLabel: row.accessibilityLabel
            )
        case .placeholder(_, let placeholder):
            return .init(
                toolTip: joined([placeholder.text], beyond: node.searchableTitle),
                accessibilityLabel: node.searchableTitle
            )
        case .cloudMachinesSection(_, let usage?):
            // The count's display host never hit-tests, so the plan's help rides
            // on the row, and the row's label keeps VoiceOver from reading the
            // visible "1/50" as "1 slash 50".
            return .init(
                toolTip: CloudTreeGroupCount(usage: usage).help,
                accessibilityLabel: [node.searchableTitle, usage.countLabel].joined(separator: ", ")
            )
        case .createAction:
            return .init(toolTip: nil, accessibilityLabel: node.searchableTitle)
        case .coderouterSection, .coderouterAddAccount:
            return .init(toolTip: nil, accessibilityLabel: node.searchableTitle)
        case .machineDetailTabs:
            return .init(toolTip: nil, accessibilityLabel: String(localized: "cloudTree.machineDetails.label", defaultValue: "Machine Details"))
        case .machineEndSpacer:
            return .init(toolTip: nil, accessibilityLabel: "")
        case .terminalsPool, .displaysPool, .workspacesGroup, .browsersGroup, .portsGroup,
             .resourcesPool, .devicesSection, .cloudMachinesSection, .coderouterSection, .coderouterAddAccount, .devicesEmpty:
            // Fixed section labels: they never truncate, so hover text would only
            // repeat what the row already reads. `.devicesEmpty` never reaches a
            // `CloudTreeCellView`, it has its own cell class; it is here so the
            // switch stays exhaustive over `Kind`.
            return .init(toolTip: nil, accessibilityLabel: node.searchableTitle)
        }
    }

    /// Identity, size and occupancy for a cmux-tui workspace. A workspace row
    /// otherwise shows only a name the machine generated, with no way to tell
    /// two of them apart.
    private static func workspaceLines(
        _ workspace: SurfaceRemoteWorkspace,
        terminalCount: Int,
        presenceHeads: [WorkspacePresenceParticipant]
    ) -> [String?] {
        var lines: [String?] = [workspace.name, workspace.detail]
        // "0 terminals" is not occupancy, it is the absence of it, and the row
        // already reads as empty. Only a count worth knowing earns a line.
        if terminalCount > 0 {
            lines.append(CloudTreeRowContentView.count(terminalCount))
        }
        if !presenceHeads.isEmpty {
            lines.append(WorkspacePresencePolicy.accessibilityLabel(presenceHeads))
        }
        return lines
    }

    /// One tooltip line per fact, dropping empties. nil when nothing is left,
    /// and nil when everything left is `title`: a popup that repeats the row's
    /// own text tells the pointer nothing and covers the rows under it.
    private static func joined(_ lines: [String?], beyond title: String? = nil) -> String? {
        let text = lines
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        if text.isEmpty { return nil }
        if text == title?.trimmingCharacters(in: .whitespacesAndNewlines) { return nil }
        return text
    }
}
