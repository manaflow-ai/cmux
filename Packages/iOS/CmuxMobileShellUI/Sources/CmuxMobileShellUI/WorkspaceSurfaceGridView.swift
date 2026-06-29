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

    private var selectedWorkspace: MobileWorkspacePreview? {
        if let selectedWorkspaceID,
           let workspace = workspaces.first(where: { $0.id == selectedWorkspaceID }) {
            return workspace
        }
        return workspaces.first
    }

    private var surfaceItems: [WorkspaceSurfaceGridItem] {
        guard let workspace = selectedWorkspace else { return [] }
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

        return items
    }

    private var filteredSurfaceItems: [WorkspaceSurfaceGridItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return surfaceItems }
        return surfaceItems.filter { item in
            item.title.localizedCaseInsensitiveContains(query)
                || item.subtitle.localizedCaseInsensitiveContains(query)
                || item.detail.localizedCaseInsensitiveContains(query)
        }
    }

    private var workspaceCountTitle: String {
        if workspaces.count == 1 {
            return L10n.string("mobile.surfaceGrid.workspaceCount.one", defaultValue: "1 Workspace")
        }
        return String(
            format: L10n.string("mobile.surfaceGrid.workspaceCount.other", defaultValue: "%d Workspaces"),
            workspaces.count
        )
    }

    var body: some View {
        ZStack {
            background

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    if isSearching {
                        searchField
                    }
                    if connectionStatus != .connected {
                        connectionBanner
                    }
                    grid
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
                addMenu

                Spacer()

                workspacePicker

                Spacer()

                Button {
                    openSelectedSurface()
                } label: {
                    Text(L10n.string("mobile.common.done", defaultValue: "Done"))
                        .fontWeight(.semibold)
                }
                .accessibilityIdentifier("MobileSurfaceGridDoneButton")
                .disabled(selectedWorkspace == nil)
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

    private var header: some View {
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

    private var grid: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 20),
                GridItem(.flexible(), spacing: 20),
            ],
            alignment: .leading,
            spacing: 24
        ) {
            ForEach(filteredSurfaceItems) { item in
                WorkspaceSurfaceGridCard(item: item) {
                    open(item)
                } close: {
                    close(item)
                }
            }
        }
        .overlay {
            if filteredSurfaceItems.isEmpty {
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

    private var addMenu: some View {
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

    private var workspacePicker: some View {
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

    private func openSelectedSurface() {
        guard let workspace = selectedWorkspace else { return }
        if browserStore.activeBrowser(for: workspace.id.rawValue) != nil {
            openBrowser(workspace.id)
            return
        }
        if let terminalID = selectedTerminalID ?? workspace.terminals.first?.id {
            openTerminal(workspace.id, terminalID)
        }
    }
}

private struct WorkspaceSurfaceGridItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case terminal(MobileTerminalPreview.ID)
        case browser
    }

    let id: String
    let workspaceID: MobileWorkspacePreview.ID
    let kind: Kind
    let title: String
    let subtitle: String
    let detail: String
    let systemImage: String
    let isSelected: Bool
    let isDimmed: Bool
    let canClose: Bool
}

private struct WorkspaceSurfaceGridCard: View {
    let item: WorkspaceSurfaceGridItem
    let open: () -> Void
    let close: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 10) {
                preview
                label
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(item.isDimmed ? 0.66 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("MobileSurfaceGridCard-\(item.id)")
    }

    private var preview: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(previewFill)
                .overlay(previewOverlay)
                .overlay(alignment: .center) {
                    previewContent
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(item.isSelected ? Color.accentColor.opacity(0.78) : .white.opacity(0.10), lineWidth: item.isSelected ? 2 : 1)
                )
                .aspectRatio(0.84, contentMode: .fit)

            if item.canClose {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .frame(width: 34, height: 34)
                        .background(Color.black.opacity(0.48), in: Circle())
                        .overlay(Circle().stroke(.white.opacity(0.15), lineWidth: 1))
                }
                .foregroundStyle(.white)
                .padding(8)
                .accessibilityLabel(L10n.string("mobile.browser.close", defaultValue: "Close Browser"))
                .accessibilityIdentifier("MobileSurfaceGridCloseButton-\(item.id)")
            }
        }
    }

    private var previewFill: some ShapeStyle {
        switch item.kind {
        case .terminal:
            return AnyShapeStyle(TerminalPalette.background)
        case .browser:
            return AnyShapeStyle(Color(uiColor: .secondarySystemBackground))
        }
    }

    private var previewOverlay: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        .white.opacity(item.kind == .browser ? 0.18 : 0.08),
                        .clear,
                        .black.opacity(item.kind == .browser ? 0.10 : 0.34),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
    }

    @ViewBuilder
    private var previewContent: some View {
        switch item.kind {
        case .terminal:
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Circle().fill(.red.opacity(0.78)).frame(width: 7, height: 7)
                    Circle().fill(.yellow.opacity(0.82)).frame(width: 7, height: 7)
                    Circle().fill(.green.opacity(0.82)).frame(width: 7, height: 7)
                    Spacer()
                }
                VStack(alignment: .leading, spacing: 6) {
                    terminalLine("$ cmux attach", opacity: 0.92)
                    terminalLine(item.title, opacity: 0.74)
                    terminalLine(item.detail.isEmpty ? "ready" : item.detail, opacity: 0.58)
                    terminalLine("▌", opacity: 0.90)
                }
                Spacer()
            }
            .padding(14)
        case .browser:
            VStack(spacing: 12) {
                HStack {
                    Capsule()
                        .fill(Color.primary.opacity(0.08))
                        .frame(height: 16)
                    Image(systemName: "line.3.horizontal")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: item.systemImage)
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 76, height: 76)
                    .background(Color.accentColor.opacity(0.12), in: Circle())
                Text(item.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(.horizontal, 6)
                Spacer()
            }
            .padding(14)
        }
    }

    private func terminalLine(_ text: String, opacity: Double) -> some View {
        Text(verbatim: text)
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundStyle(TerminalPalette.foreground.opacity(opacity))
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private var label: some View {
        HStack(spacing: 8) {
            Image(systemName: item.systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(item.kind == .browser ? Color.accentColor : TerminalPalette.foreground)
                .frame(width: 22)
            Text(item.title)
                .font(.headline.weight(.semibold))
                .foregroundStyle(TerminalPalette.foreground)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}
