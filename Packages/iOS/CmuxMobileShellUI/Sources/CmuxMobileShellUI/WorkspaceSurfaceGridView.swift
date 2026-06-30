import CmuxMobileBrowser
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI
#if os(iOS)
import UIKit
#endif

struct WorkspaceSurfaceGridView: View {
    let workspaces: [MobileWorkspacePreview]
    let selectedWorkspaceID: MobileWorkspacePreview.ID?
    let selectedTerminalID: MobileTerminalPreview.ID?
    let host: String
    let connectionStatus: MobileMacConnectionStatus
    let canCreateWorkspace: Bool
    let canCreateTerminal: Bool
    let selectWorkspace: (MobileWorkspacePreview.ID) -> Void
    let openTerminal: (MobileWorkspacePreview.ID, MobileTerminalPreview.ID) -> Void
    let openBrowser: (MobileWorkspacePreview.ID) -> Void
    let closeBrowser: (MobileWorkspacePreview.ID) -> Void
    let createWorkspace: () -> Void
    let createTerminal: (MobileWorkspacePreview.ID) -> Void
    let showSettings: () -> Void
    let showDevices: (() -> Void)?
    let reconnect: (() -> Void)?

    @Environment(BrowserSurfaceStore.self) private var browserStore
    @State private var isSearching = false
    @State private var searchText = ""

    private var content: WorkspaceSurfaceGridContent {
        if let selectedWorkspaceID,
           let workspace = workspaces.first(where: { $0.id == selectedWorkspaceID }) {
            return makeContent(for: workspace)
        }
        return makeContent(for: nil)
    }

    private func makeContent(for workspace: MobileWorkspacePreview?) -> WorkspaceSurfaceGridContent {
        guard let workspace else {
            return WorkspaceSurfaceGridContent(selectedWorkspace: nil, filteredSurfaceItems: [])
        }

        var items = workspace.terminals.map { terminal in
            WorkspaceSurfaceGridItem(
                id: "terminal-\(terminal.id.rawValue)",
                workspaceID: workspace.id,
                kind: .terminal(terminal.id),
                title: terminal.name,
                subtitle: terminal.isReady
                    ? L10n.string("mobile.surfaceGrid.terminalReady", defaultValue: "Terminal")
                    : L10n.string("mobile.surfaceGrid.terminalStarting", defaultValue: "Starting"),
                detail: workspace.previewLine,
                systemImage: terminal.isFocused ? "terminal.fill" : "terminal",
                isSelected: terminal.id == selectedTerminalID && browserStore.activeBrowser(for: workspace.id.rawValue) == nil,
                isDimmed: connectionStatus != .connected || !terminal.isReady,
                canClose: false
            )
        }

        if let browser = browserStore.activeBrowser(for: workspace.id.rawValue) {
            items.insert(
                WorkspaceSurfaceGridItem(
                    id: "browser-\(browser.id.rawValue)",
                    workspaceID: workspace.id,
                    kind: .browser,
                    title: browser.title ?? L10n.string("mobile.surfaceGrid.browserTitle", defaultValue: "Browser"),
                    subtitle: L10n.string("mobile.surfaceGrid.browser", defaultValue: "Browser"),
                    detail: browser.currentURL?.absoluteString
                        ?? L10n.string("mobile.surfaceGrid.browserAddressEmpty", defaultValue: "No page loaded"),
                    systemImage: "globe",
                    isSelected: true,
                    isDimmed: connectionStatus != .connected,
                    canClose: true
                ),
                at: 0
            )
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return WorkspaceSurfaceGridContent(selectedWorkspace: workspace, filteredSurfaceItems: items)
        }
        let filteredItems = items.filter { item in
            item.title.localizedCaseInsensitiveContains(query)
                || item.subtitle.localizedCaseInsensitiveContains(query)
                || item.detail.localizedCaseInsensitiveContains(query)
        }
        return WorkspaceSurfaceGridContent(selectedWorkspace: workspace, filteredSurfaceItems: filteredItems)
    }

    private var workspaceCountTitle: String {
        String.localizedStringWithFormat(
            L10n.string("mobile.surfaceGrid.workspaceCount", defaultValue: "%d Workspaces"),
            workspaces.count
        )
    }

    var body: some View {
        let gridContent = content

        ZStack {
            background

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header(selectedWorkspace: gridContent.selectedWorkspace)
                    if isSearching {
                        searchField
                    }
                    if connectionStatus != .connected {
                        connectionBanner
                    }
                    grid(items: gridContent.filteredSurfaceItems)
                }
                .padding(.horizontal, 20)
                .padding(.top, 28)
                .padding(.bottom, 72)
            }
            .scrollIndicators(.hidden)
            .safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: 76)
            }
            .accessibilityIdentifier("MobileWorkspaceSurfaceGrid")
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarLeading) {
                Button(action: showSettings) {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel(L10n.string("mobile.workspaces.settings", defaultValue: "Settings"))
                .accessibilityIdentifier("MobileSurfaceGridSettingsButton")

                if let showDevices {
                    Button(action: showDevices) {
                        Image(systemName: "desktopcomputer")
                    }
                    .accessibilityLabel(L10n.string("mobile.computers.title", defaultValue: "Computers"))
                    .accessibilityIdentifier("MobileSurfaceGridDevicesButton")
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    withAnimation(.snappy(duration: 0.22)) {
                        isSearching.toggle()
                        if !isSearching {
                            searchText = ""
                        }
                    }
                } label: {
                    Image(systemName: isSearching ? "xmark.circle.fill" : "magnifyingglass")
                }
                .accessibilityLabel(L10n.string("mobile.surfaceGrid.search", defaultValue: "Search Surfaces"))
                .accessibilityIdentifier("MobileSurfaceGridSearchButton")
            }

            ToolbarItemGroup(placement: .bottomBar) {
                addMenu(selectedWorkspace: gridContent.selectedWorkspace)

                Spacer()

                workspacePicker(selectedWorkspace: gridContent.selectedWorkspace)

                Spacer()

                Button {
                    openSelectedSurface(in: gridContent.selectedWorkspace)
                } label: {
                    Text(L10n.string("mobile.common.done", defaultValue: "Done"))
                        .fontWeight(.semibold)
                }
                .accessibilityIdentifier("MobileSurfaceGridDoneButton")
                .disabled(gridContent.selectedWorkspace == nil)
            }
        }
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarBackground(Color(red: 0.09, green: 0.10, blue: 0.10), for: .bottomBar)
        .toolbarBackground(.visible, for: .bottomBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .bottomBar)
    }

    private var background: some View {
        LinearGradient(
            colors: [
                TerminalPalette.background.opacity(0.96),
                Color(red: 0.18, green: 0.20, blue: 0.16),
                Color(red: 0.09, green: 0.10, blue: 0.10),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }

    private func header(selectedWorkspace: MobileWorkspacePreview?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(selectedWorkspace?.name ?? L10n.string("mobile.workspace.emptyTitle", defaultValue: "No Workspace"))
                .font(.system(size: 44, weight: .bold, design: .default))
                .foregroundStyle(TerminalPalette.foreground)
                .lineLimit(2)
                .minimumScaleFactor(0.72)
                .accessibilityIdentifier("MobileSurfaceGridWorkspaceTitle")

            Text(host)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(TerminalPalette.dimForeground.opacity(0.82))
                .lineLimit(1)
        }
    }

    private var searchField: some View {
        TextField(
            L10n.string("mobile.surfaceGrid.searchPlaceholder", defaultValue: "Search terminals and browsers"),
            text: $searchText
        )
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .padding(.horizontal, 14)
        .frame(height: 46)
        .foregroundStyle(TerminalPalette.foreground)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.white.opacity(0.14), lineWidth: 1)
        )
        .accessibilityIdentifier("MobileSurfaceGridSearchField")
    }

    private var connectionBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: connectionStatus == .reconnecting ? "arrow.triangle.2.circlepath" : "wifi.slash")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(connectionStatus.label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(TerminalPalette.foreground)
                Text(host)
                    .font(.caption)
                    .foregroundStyle(TerminalPalette.dimForeground)
            }
            Spacer()
            if let reconnect {
                Button(action: reconnect) {
                    Text(L10n.string("mobile.workspace.reconnect", defaultValue: "Reconnect"))
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityIdentifier("MobileSurfaceGridConnectionBanner")
    }

    private func grid(items: [WorkspaceSurfaceGridItem]) -> some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 20),
                GridItem(.flexible(), spacing: 20),
            ],
            alignment: .leading,
            spacing: 24
        ) {
            ForEach(items) { item in
                WorkspaceSurfaceGridCard(item: item) {
                    open(item)
                } close: {
                    close(item)
                }
            }
        }
        .overlay {
            if items.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: searchText.isEmpty ? "rectangle.stack.badge.plus" : "magnifyingglass")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(TerminalPalette.dimForeground)
            Text(
                searchText.isEmpty
                    ? L10n.string("mobile.surfaceGrid.empty", defaultValue: "No surfaces")
                    : L10n.string("mobile.surfaceGrid.noResults", defaultValue: "No matching surfaces")
            )
            .font(.headline)
            .foregroundStyle(TerminalPalette.foreground)
        }
    }

    private func addMenu(selectedWorkspace: MobileWorkspacePreview?) -> some View {
        Menu {
            if let selectedWorkspace {
                Button {
                    createTerminal(selectedWorkspace.id)
                } label: {
                    Label(L10n.string("mobile.terminal.new", defaultValue: "New Terminal"), systemImage: "terminal")
                }
                .disabled(!canCreateTerminal)
                .accessibilityIdentifier("MobileSurfaceGridNewTerminalMenuItem")

                Button {
                    openBrowser(selectedWorkspace.id)
                } label: {
                    Label(L10n.string("mobile.browser.new", defaultValue: "New Browser"), systemImage: "globe")
                }
                .accessibilityIdentifier("MobileSurfaceGridNewBrowserMenuItem")
            }

            Button(action: createWorkspace) {
                Label(L10n.string("mobile.workspace.new", defaultValue: "New Workspace"), systemImage: "plus.square.on.square")
            }
            .disabled(!canCreateWorkspace)
            .accessibilityIdentifier("MobileSurfaceGridNewWorkspaceMenuItem")
        } label: {
            Label(L10n.string("mobile.surfaceGrid.add", defaultValue: "Add Surface"), systemImage: "plus")
                .labelStyle(.iconOnly)
        }
        .accessibilityLabel(L10n.string("mobile.surfaceGrid.add", defaultValue: "Add Surface"))
        .accessibilityIdentifier("MobileSurfaceGridAddButton")
    }

    private func workspacePicker(selectedWorkspace: MobileWorkspacePreview?) -> some View {
        Menu {
            ForEach(workspaces) { workspace in
                Button {
                    selectWorkspace(workspace.id)
                } label: {
                    Label(
                        workspace.name,
                        systemImage: workspace.id == selectedWorkspace?.id ? "checkmark.circle.fill" : workspace.avatarSymbolName
                    )
                }
                .accessibilityIdentifier("MobileSurfaceGridWorkspaceMenuItem-\(workspace.id.rawValue)")
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.stack")
                    .fixedSize()
                Text("\(workspaces.count)")
                    .fixedSize()
                Text(selectedWorkspace?.name ?? L10n.string("mobile.workspace.emptyTitle", defaultValue: "No Workspace"))
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(-1)
            }
            .frame(maxWidth: 170)
        }
        .disabled(workspaces.isEmpty)
        .accessibilityLabel(workspaceCountTitle)
        .accessibilityIdentifier("MobileSurfaceGridWorkspacePicker")
    }

    private func open(_ item: WorkspaceSurfaceGridItem) {
        switch item.kind {
        case .terminal(let terminalID):
            openTerminal(item.workspaceID, terminalID)
        case .browser:
            openBrowser(item.workspaceID)
        }
    }

    private func close(_ item: WorkspaceSurfaceGridItem) {
        guard case .browser = item.kind else { return }
        closeBrowser(item.workspaceID)
    }

    private func openSelectedSurface(in workspace: MobileWorkspacePreview?) {
        guard let workspace else { return }
        if browserStore.activeBrowser(for: workspace.id.rawValue) != nil {
            openBrowser(workspace.id)
            return
        }
        let selection = WorkspaceSurfaceGridSelection(
            workspace: workspace,
            selectedTerminalID: selectedTerminalID
        )
        if let terminalID = selection.terminalIDToOpen() {
            openTerminal(workspace.id, terminalID)
        }
    }
}

private struct WorkspaceSurfaceGridContent {
    let selectedWorkspace: MobileWorkspacePreview?
    let filteredSurfaceItems: [WorkspaceSurfaceGridItem]
}

struct WorkspaceSurfaceGridSelection {
    let workspace: MobileWorkspacePreview
    let selectedTerminalID: MobileTerminalPreview.ID?

    func terminalIDToOpen() -> MobileTerminalPreview.ID? {
        if let selectedTerminalID,
           workspace.terminals.contains(where: { $0.id == selectedTerminalID }) {
            return selectedTerminalID
        }
        return workspace.terminals.first?.id
    }
}
