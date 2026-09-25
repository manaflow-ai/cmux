import CmuxFoundation
import CmuxSurfaceCatalogModel
import CmuxWorkspacePresence
import CmuxSurfaceCatalogModel
import SwiftUI
enum CloudTreeIconPalette {
    static let workspace = Color.blue
    static let terminal = Color.indigo
    static let display = Color.teal
    static let browser = Color.orange
    static let machine = Color.accentColor
}
struct CloudTreeRowContentView: View {
    let kind: CloudTreeNode.Kind
    var presenceHeads: [WorkspacePresenceParticipant] = []
    var style: CloudTreeStyle = CloudTreeStyleStore.current

    private static func nonEmptyTrimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
    var body: some View {
        row
            .overlay(alignment: .bottom) {
                if style.rowSeparators, showsSeparator {
                    Rectangle()
                        .fill(Color.primary.opacity(0.07))
                        .frame(height: 0.5)
                        .padding(.trailing, style.rowGrid.trailingPadding)
                }
            }
    }

    private var showsSeparator: Bool {
        switch kind {
        case .machine, .pendingMachine, .localMachine, .placeholder, .device: return false
        default: return true
        }
    }
    @MainActor @ViewBuilder
    private var row: some View {
        switch kind {
        case .machine(let machine, _):
            CloudTreeMachineRowContent(machine: machine, style: style)
        case .pendingMachine(let operation):
            CloudTreePendingMachineRowContent(operation: operation, style: style)
        case .localMachine(let row):
            CloudTreeLocalMachineRowContent(row: row, style: style)
        case .device(let row):
            CloudTreeDeviceRowContent(row: row, style: style)
        case .devicesSection(let section):
            groupRow(title: String(localized: "cloudTree.group.devices", defaultValue: "My Devices"), count: section.count)
        case .cloudMachinesSection:
            groupRow(title: String(localized: "cloudTree.group.cloudMachines", defaultValue: "Cloud Machines"))
        case .devicesEmpty:
            EmptyView()
        case .terminalsPool(_, let count):
            groupRow(title: String(localized: "cloudTree.group.terminals", defaultValue: "Terminals"), count: count)
        case .displaysPool(_, let count, _):
            groupRow(title: String(localized: "cloudTree.group.displays", defaultValue: "Displays"), count: count)
        case .workspacesGroup:
            groupRow(title: String(localized: "cloudTree.group.workspaces", defaultValue: "Workspaces"))
        case .workspace(_, let workspace, _, _, _):
            // No open marker here (none on any row since #11069); the row's open
            // verb reads "Go to Workspace" when it is already showing locally.
            CloudTreeLeafRow(
                style: style,
                icon: "folder.fill",
                tint: CloudTreeIconPalette.workspace,
                title: workspace.name,
                titleWeight: workspace.focused ? .medium : .regular,
                accessories: {
                    if !presenceHeads.isEmpty {
                        SidebarWorkspacePresenceHeadsView(participants: presenceHeads)
                    }
                }
            )
        case .localWorkspace(let row):
            CloudTreeLeafRow(
                style: style,
                icon: "folder.fill",
                tint: CloudTreeIconPalette.workspace,
                title: row.title,
                titleWeight: row.isSelected ? .medium : .regular
            )
        case .terminal(let row):
            CloudTreeTerminalRowContent(row: row, style: style)
        case .display(let resource, _, let remoteView):
            let title = Self.nonEmptyTrimmed(remoteView?.name)
                ?? (resource.title.isEmpty ? String(localized: "cloudTree.node.desktop", defaultValue: "Desktop") : resource.title)
            CloudTreeLeafRow(
                style: style,
                icon: "display",
                tint: CloudTreeIconPalette.display,
                title: title
            )
            .help([title, Self.text(for: resource)].joined(separator: "\n"))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel([title, Self.text(for: resource)].joined(separator: ", "))
        case .browsersGroup:
            groupRow(title: String(localized: "cloudTree.group.browsers", defaultValue: "Browsers"))
        case .browser(let row):
            CloudTreeLeafRow(
                style: style,
                icon: "globe",
                tint: CloudTreeIconPalette.browser,
                title: row.resource.title.isEmpty ? String(localized: "cloudTree.browser.untitled", defaultValue: "browser") : row.resource.title,
                detail: CloudTreeBrowserDetail.text(for: row)
            )
        case .portsGroup:
            CloudTreeGroupRowContent(title: String(localized: "cloudTree.group.ports", defaultValue: "Ports"), count: nil, style: style)
        case .resourcesPool:
            CloudTreeGroupRowContent(title: String(localized: "cloudTree.group.resources", defaultValue: "Resources"), count: nil, style: style)
        case .resource(_, let row):
            CloudTreeMachineResourceRowContent(row: row, style: style)
        case .port(let resource, let url, _):
            CloudTreeLeafRow(
                style: style,
                icon: "network",
                tint: CloudTreeIconPalette.browser,
                title: url.map(CloudTreePortLinkText.displayText)
                    ?? (resource.id.forwardedPort ?? resource.port).map(String.init)
                    ?? resource.title,
                titleIsLink: url != nil,
                detail: url == nil ? (resource.detail?.isEmpty == false ? resource.detail : nil) : nil
            )
        case .placeholder(_, let placeholder):
            CloudTreePlaceholderContent(placeholder: placeholder, style: style)
        }
    }
    /// One section label ("Workspaces", "My Devices") in the shared group row,
    /// so the row switch stays a list of one-line cases.
    private func groupRow(title: String, count: Int? = nil) -> some View {
        CloudTreeGroupRowContent(title: title, count: count, style: style)
    }

    /// Formats terminal totals for group and machine summaries.
    static func count(_ terminals: Int) -> String {
        terminals == 1
            ? String(localized: "cloudTree.workspace.terminalCount.one", defaultValue: "1 terminal")
            : String(format: String(localized: "cloudTree.workspace.terminalCount.other", defaultValue: "%d terminals"), terminals)
    }

    /// Formats the transport and screen label shown in a VNC display row's tooltip.
    /// A key such as `display:1` becomes `noVNC · :1`; unknown key shapes retain
    /// the transport-only detail.
    static func text(for resource: SurfaceResource) -> String {
        let transport = String(localized: "cloudTree.node.desktop.detail", defaultValue: "noVNC")
        guard let screen = screenLabel(displayKey: resource.id.key) else { return transport }
        return String(
            format: String(localized: "cloudTree.node.desktop.detail.screen", defaultValue: "%1$@ · %2$@"),
            transport,
            screen
        )
    }

    /// Converts a display resource key such as `display:1` to its X display
    /// label (`:1`), returning nil for keys that are not numbered displays.
    static func screenLabel(displayKey key: String) -> String? {
        let prefix = "display:"
        guard key.hasPrefix(prefix) else { return nil }
        let number = key.dropFirst(prefix.count)
        return number.isEmpty ? nil : ":\(number)"
    }
}

/// The shared leaf-row chrome: icon slot, then title and detail arranged per
/// the style's leaf layout and metadata placement, then trailing accessories.
/// The scheme-free form of a port link for display (`host:port`, VS Code's
/// forwarded-ports style) — never used for opening or copying, only for the
/// row's title text.
enum CloudTreePortLinkText {
    static func displayText(forURL url: String) -> String {
        guard let range = url.range(of: "://") else { return url }
        return String(url[range.upperBound...])
    }
}

struct CloudTreeLeafRow<Accessories: View>: View {
    let style: CloudTreeStyle
    let icon: String
    let tint: Color
    var iconAsset: String? = nil
    let title: String
    var titleWeight: Font.Weight = .regular
    var titleDimmed: Bool = false
    /// Underlined and tinted like a followable link (VS Code's forwarded-ports
    /// panel): a port row's URL is the one title in this tree a click actually
    /// navigates, so it reads as a link rather than a label.
    var titleIsLink: Bool = false
    var detail: String?
    @Environment(\.cmuxGlobalFontMagnificationPercent) private var magnification
    @ViewBuilder var accessories: () -> Accessories

    init(
        style: CloudTreeStyle,
        icon: String,
        tint: Color,
        iconAsset: String? = nil,
        title: String,
        titleWeight: Font.Weight = .regular,
        titleDimmed: Bool = false,
        titleIsLink: Bool = false,
        detail: String? = nil,
        @ViewBuilder accessories: @escaping () -> Accessories
    ) {
        self.style = style
        self.icon = icon
        self.tint = tint
        self.iconAsset = iconAsset
        self.title = title
        self.titleWeight = titleWeight
        self.titleDimmed = titleDimmed
        self.titleIsLink = titleIsLink
        self.detail = detail
        self.accessories = accessories
    }

    var body: some View {
        HStack(alignment: .center, spacing: GlobalFontMagnification.scaledSize(style.iconGap, percent: magnification)) {
            if style.iconSlot > 0 {
                CloudTreeRowIcon(
                    style: style,
                    systemName: icon,
                    tint: tint,
                    assetName: iconAsset,
                    dimmed: titleDimmed
                )
            }
            switch style.leafLayout {
            case .twoLine:
                VStack(alignment: .leading, spacing: 1) {
                    titleText
                    if let detail, !detail.isEmpty {
                        detailText(detail)
                    }
                }
                Spacer(minLength: style.rowGrid.trailingGap)
            case .singleLine:
                switch style.metaPlacement {
                case .inline:
                    HStack(alignment: .firstTextBaseline, spacing: style.rowGrid.detailGap) {
                        titleText
                        if let detail, !detail.isEmpty {
                            detailText(detail)
                        }
                    }
                    Spacer(minLength: style.rowGrid.trailingGap)
                case .trailing:
                    titleText
                    Spacer(minLength: style.rowGrid.trailingGap)
                    if let detail, !detail.isEmpty {
                        detailText(detail)
                    }
                }
            }
            accessories()
        }
        .padding(.trailing, style.rowGrid.trailingPadding)
    }

    private var titleText: some View {
        Text(title)
            .cmuxFont(size: style.titleSize, weight: titleWeight, design: style.fontDesign)
            .foregroundStyle(titleColor)
            .underline(titleIsLink)
            .lineLimit(1)
            .truncationMode(.tail)
            .layoutPriority(1)
    }

    private var titleColor: AnyShapeStyle {
        // Underlined-but-primary, not accent-tinted: a port link sits among
        // plain-text rows in the same tree, and the accent color read as an
        // unrelated highlight rather than "this text is a link" the way the
        // underline alone already says.
        titleDimmed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary)
    }

    private func detailText(_ text: String) -> some View {
        Text(text)
            .cmuxFont(size: style.detailSize, design: style.fontDesign)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .truncationMode(.middle)
    }
}

extension CloudTreeLeafRow where Accessories == EmptyView {
    init(
        style: CloudTreeStyle,
        icon: String,
        tint: Color,
        iconAsset: String? = nil,
        title: String,
        titleWeight: Font.Weight = .regular,
        titleDimmed: Bool = false,
        titleIsLink: Bool = false,
        detail: String? = nil
    ) {
        self.init(
            style: style,
            icon: icon,
            tint: tint,
            iconAsset: iconAsset,
            title: title,
            titleWeight: titleWeight,
            titleDimmed: titleDimmed,
            titleIsLink: titleIsLink,
            detail: detail,
            accessories: { EmptyView() }
        )
    }
}

/// A cmux-tui terminal row with its provider mark, title, directory and optional view count.
struct CloudTreeTerminalRowContent: View {
    let row: CloudTreeTerminalRow
    var style: CloudTreeStyle = CloudTreeStyleStore.current

    private var terminal: SurfaceResource { row.resource }

    /// Detached styling is reserved for a live terminal whose resolved daemon
    /// view list is empty. A stale exited record can have the same empty list,
    /// but must retain the ordinary exited presentation.
    private var showsDetachedState: Bool {
        guard row.isDetached else { return false }
        switch terminal.lifecycle {
        case .launching, .running:
            return true
        case .exited, .unavailable:
            return false
        }
    }

    var body: some View {
        CloudTreeLeafRow(
            style: style,
            icon: glyph,
            tint: CloudTreeIconPalette.terminal,
            iconAsset: terminal.terminalAgentIconAssetName,
            title: row.displayTitle.isEmpty ? String(localized: "cloudTree.terminal.untitled", defaultValue: "terminal") : row.displayTitle,
            titleDimmed: terminal.lifecycle == .exited || showsDetachedState
        )
        .help(toolTip)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(toolTip)
    }

    /// Keep secondary information on hover so the narrow row gives its width to the title.
    var toolTip: String {
        var details = [row.displayTitle, row.directoryHelp, agentLabel].compactMap { $0 }
        if showsDetachedState {
            details.append(String(localized: "cloudTree.terminal.detached.help", defaultValue: "Still running on the machine, but no tab shows it. Click to open it in a pane; right-click to kill it."))
        } else if let views = Self.multiplierBadge(row.viewBadge) {
            details.append(Self.viewsHelp(views))
        }
        return details.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// The multiple-tab count retained in pool-row tooltips.
    static func multiplierBadge(_ views: Int?) -> Int? {
        guard let views, views > 1 else { return nil }
        return views
    }

    static func viewsHelp(_ views: Int) -> String {
        String(format: String(localized: "cloudTree.terminal.views.other", defaultValue: "%d tabs on the machine show this terminal"), views)
    }

    private var glyph: String {
        switch terminal.lifecycle {
        case .launching, .running: return "terminal"
        case .exited: return "xmark.rectangle"
        case .unavailable: return "terminal"
        }
    }

    /// "source · state" for the tooltip; nil when no agent is attached.
    private var agentLabel: String? {
        guard let agent = terminal.agent else { return nil }
        let source = agent.source?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let state = agent.state.trimmingCharacters(in: .whitespacesAndNewlines)
        if source.isEmpty, state.isEmpty { return nil }
        if !source.isEmpty, !state.isEmpty { return "\(source) · \(state)" }
        return source.isEmpty ? state : source
    }

    static func abbreviated(_ path: String) -> String {
        // A cloud machine's home reads as `~`, the way this Mac's rows do: the account
        // name is noise in a cwd column. `/home/cmux` on a current devbox image, `/root`
        // on a machine from an image that predates the non-root work user.
        if path == "/root" { return "~" }
        if path.hasPrefix("/root/") { return "~" + path.dropFirst("/root".count) }
        if let range = path.range(of: "^/home/[^/]+", options: .regularExpression) {
            let home = String(path[range])
            if path == home { return "~" }
            if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        }
        if let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty {
            if path == home { return "~" }
            if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        }
        return path
    }
}

/// The browser row's dim detail: URL host, else the local workspace showing it.
enum CloudTreeBrowserDetail {
    static func text(for row: CloudTreeBrowserRow) -> String? {
        if let url = row.resource.url, let host = URL(string: url)?.host, !host.isEmpty { return host }
        return row.workspaceTitle
    }
}
