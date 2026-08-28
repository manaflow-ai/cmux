import AppKit
import CmuxFoundation
import SwiftUI

/// Right-sidebar Harbor panel: every attachable terminal session on this Mac
/// and on user-added SSH hosts (cmux-tui, tmux, zellij, screen, zmx, herdr).
/// Drag a row into the workspace to attach to it in a new pane; double-click
/// attaches in the focused pane.
struct HarborPanelView: View {
    // Plain reference on purpose: only action closures touch it, so the
    // panel must not re-evaluate on every TabManager change.
    let tabManager: TabManager
    let chromeBackgroundColor: NSColor

    @StateObject private var viewModel = HarborPanelViewModel()
    @State private var dragCoordinator = HarborDragCoordinator()
    @State private var isAddHostPresented = false
    @State private var newHostDestination = ""

    var body: some View {
        VStack(spacing: 0) {
            header
                .rightSidebarChromeBar()
                .rightSidebarChromeBottomBorder(backgroundColor: chromeBackgroundColor)
            if !TuiTerminalAttachBridge.isManualIOEnabled {
                manualIOOffNotice
            }
            content
        }
        .onAppear { viewModel.refresh() }
        .accessibilityIdentifier("HarborPanel")
    }

    private var header: some View {
        HStack(spacing: RightSidebarChromeMetrics.headerControlSpacing) {
            Text(String(localized: "harbor.header.title", defaultValue: "Harbor"))
                .cmuxFont(size: 12, weight: .semibold)
                .foregroundColor(.secondary)
            Spacer(minLength: 4)
            Button {
                isAddHostPresented = true
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.plain)
            .help(String(localized: "harbor.action.addHost", defaultValue: "Add SSH Host…"))
            .accessibilityIdentifier("HarborAddHostButton")
            .popover(isPresented: $isAddHostPresented, arrowEdge: .bottom) {
                addHostPopover
            }
            Button {
                viewModel.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isRefreshing)
            .help(String(localized: "harbor.action.refresh", defaultValue: "Refresh"))
            .accessibilityIdentifier("HarborRefreshButton")
        }
    }

    private var addHostPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "harbor.addHost.title", defaultValue: "Add SSH Host"))
                .cmuxFont(size: 12, weight: .semibold)
            TextField(
                String(localized: "harbor.addHost.placeholder", defaultValue: "user@host or ssh alias"),
                text: $newHostDestination
            )
            .textFieldStyle(.roundedBorder)
            .frame(width: 220)
            .onSubmit(submitNewHost)
            HStack {
                Spacer()
                Button(String(localized: "harbor.addHost.add", defaultValue: "Add"), action: submitNewHost)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!HarborHostStore.isPlausibleDestination(
                        newHostDestination.trimmingCharacters(in: .whitespacesAndNewlines)
                    ))
            }
        }
        .padding(12)
    }

    private var manualIOOffNotice: some View {
        Text(String(
            localized: "harbor.notice.manualIOOff",
            defaultValue: "Manual IO beta is off. Dropped sessions open in a plain terminal instead of a daemon-backed pane."
        ))
        .cmuxFont(size: 11)
        .foregroundColor(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.yellow.opacity(0.12))
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2, pinnedViews: []) {
                ForEach(viewModel.sections) { section in
                    HarborSectionView(
                        section: section,
                        beginDrag: beginDrag,
                        onAttach: attach,
                        onRemoveHost: { destination in
                            viewModel.removeHost(destination)
                        }
                    )
                }
            }
            .padding(.vertical, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func submitNewHost() {
        if viewModel.addHost(newHostDestination) {
            newHostDestination = ""
            isAddHostPresented = false
        }
    }

    private func beginDrag(
        _ session: HarborSession,
        _ sourceView: NSView,
        _ event: NSEvent,
        _ frame: NSRect,
        _ image: NSImage
    ) -> Bool {
        guard let app = AppDelegate.shared else { return false }
        return dragCoordinator.beginDrag(
            session,
            registry: app.harborSessionDragRegistry,
            tabDragTransferRegistry: app.tabDragTransferRegistry,
            from: sourceView,
            event: event,
            frame: frame,
            image: image
        )
    }

    private func attach(_ session: HarborSession) {
        guard let workspace = tabManager.tabs.first(where: { $0.id == tabManager.selectedTabId }) else {
            NSSound.beep()
            return
        }
        _ = workspace.attachHarborSessionInFocusedPane(session: session)
    }
}

private struct HarborSectionView: View {
    let section: HarborSourceSection
    let beginDrag: HarborDragBeginAction
    let onAttach: @MainActor (HarborSession) -> Void
    let onRemoveHost: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            sectionHeader
            if section.sessions.isEmpty {
                emptyOrStatusRow
            } else {
                ForEach(section.sessions) { session in
                    HarborSessionRow(
                        session: session,
                        beginDrag: beginDrag,
                        onAttach: onAttach
                    )
                }
            }
        }
        .padding(.bottom, 8)
    }

    private var sectionHeader: some View {
        HStack(spacing: 5) {
            Image(systemName: section.source.isLocal ? "desktopcomputer" : "network")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            Text(section.source.displayName)
                .cmuxFont(size: 11, weight: .semibold)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if section.status == .loading {
                ProgressView()
                    .controlSize(.mini)
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .contextMenu {
            if case .ssh(let destination) = section.source {
                Button {
                    onRemoveHost(destination)
                } label: {
                    Text(String(localized: "harbor.host.remove", defaultValue: "Remove Host"))
                }
            }
        }
    }

    @ViewBuilder
    private var emptyOrStatusRow: some View {
        switch section.status {
        case .loading:
            EmptyView()
        case .loaded:
            Text(String(localized: "harbor.empty", defaultValue: "No sessions found."))
                .cmuxFont(size: 11)
                .foregroundColor(.secondary.opacity(0.7))
                .padding(.leading, 27)
                .padding(.vertical, 2)
        case .unreachable(let reason):
            Text(String(
                localized: "harbor.host.unreachable",
                defaultValue: "Unreachable: \(reason)"
            ))
            .cmuxFont(size: 11)
            .foregroundColor(.orange)
            .lineLimit(2)
            .padding(.leading, 27)
            .padding(.vertical, 2)
        }
    }
}

private struct HarborSessionRow: View, Equatable {
    let session: HarborSession
    let beginDrag: HarborDragBeginAction
    let onAttach: @MainActor (HarborSession) -> Void
    @State private var isHovered = false

    static func == (lhs: HarborSessionRow, rhs: HarborSessionRow) -> Bool {
        // Skip body re-eval during scroll when the session is unchanged.
        // Closures come from stable parent state and are not compared.
        lhs.session == rhs.session
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: session.tool.symbolName)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(width: 14)
            Text(session.name)
                .cmuxFont(size: 13)
                .foregroundColor(.primary.opacity(0.92))
                .lineLimit(1)
                .truncationMode(.tail)
            Text(session.tool.displayName)
                .cmuxFont(size: 10)
                .foregroundColor(.secondary.opacity(0.7))
            Spacer(minLength: 8)
            Text(session.state.label)
                .cmuxFont(size: 10)
                .foregroundColor(stateColor.opacity(0.9))
                .fixedSize()
        }
        .padding(.leading, 24)
        .padding(.trailing, 12)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(rowBackground)
        .onHover { isHovered = $0 }
        .help(helpText)
        .overlay(HarborDragSource(
            session: session,
            beginDrag: beginDrag,
            onDoubleClick: { onAttach(session) }
        ))
        .contextMenu {
            Button {
                onAttach(session)
            } label: {
                Text(String(localized: "harbor.row.attach", defaultValue: "Attach in Current Workspace"))
            }
        }
        .accessibilityIdentifier("HarborSessionRow.\(session.id)")
    }

    private var stateColor: Color {
        switch session.state {
        case .attached, .running: return .green
        case .detached: return .secondary
        case .exited, .stopped: return .orange
        case .unknown: return .secondary
        }
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(isHovered ? Color.primary.opacity(0.05) : Color.clear)
            .padding(.horizontal, 6)
    }

    private var helpText: String {
        var lines = ["\(session.tool.displayName): \(session.name)"]
        if !session.detail.isEmpty {
            lines.append(session.detail)
        }
        lines.append(HarborAttachCommand.shellCommand(for: session))
        return lines.joined(separator: "\n")
    }
}
