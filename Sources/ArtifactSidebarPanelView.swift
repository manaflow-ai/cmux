import AppKit
import CmuxArtifacts
import SwiftUI

/// Beta-gated Artifacts sidebar with live filesystem tree and search.
struct ArtifactSidebarPanelView: View {
    let model: ArtifactSidebarModel
    let workspace: ArtifactSidebarWorkspace?
    let isVisible: Bool
    let onOpenArtifact: (ArtifactSidebarRowSnapshot) -> Void

    var body: some View {
        VStack(spacing: 0) {
            searchHeader
                .rightSidebarChromeBottomBorder()
            content
        }
        .task(id: ArtifactSidebarBinding(
            workspaceID: workspace?.id,
            workingDirectory: workspace?.workingDirectory,
            isVisible: isVisible
        )) {
            if isVisible {
                await model.bind(workspace: workspace)
            } else {
                model.stop()
            }
        }
        .onChange(of: workspace?.title) { _, title in
            guard let workspaceID = workspace?.id else { return }
            model.updateWorkspaceTitle(workspaceID: workspaceID, title: title)
        }
        .onDisappear {
            model.stop()
        }
        .alert(item: actionFailureBinding) { failure in
            Alert(
                title: Text(failureTitle(failure)),
                message: Text(failureMessage(failure)),
                dismissButton: .default(Text(String(localized: "common.ok", defaultValue: "OK")))
            )
        }
        .accessibilityIdentifier("ArtifactSidebarPanel")
    }

    private var searchHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(
                String(localized: "rightSidebar.artifacts.search.placeholder", defaultValue: "Search artifacts"),
                text: Binding(get: { model.query }, set: model.setQuery)
            )
            .textFieldStyle(.plain)
            .accessibilityIdentifier("ArtifactSidebarSearchField")
            Button(action: presentAddPanel) {
                Image(systemName: "plus")
            }
            .buttonStyle(.plain)
            .safeHelp(String(localized: "rightSidebar.artifacts.add.tooltip", defaultValue: "Add files to Artifacts"))
            .disabled(workspace == nil)
            .accessibilityIdentifier("ArtifactSidebarAddButton")
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .unavailable:
            emptyState(
                symbol: "shippingbox",
                title: String(localized: "rightSidebar.artifacts.noWorkspace.title", defaultValue: "No Local Workspace"),
                message: String(localized: "rightSidebar.artifacts.noWorkspace.message", defaultValue: "Open a local workspace to browse its artifacts."),
                showsAddButton: false
            )
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel(String(localized: "rightSidebar.artifacts.loading", defaultValue: "Loading artifacts"))
        case .failed:
            VStack(spacing: 10) {
                emptyState(
                    symbol: "exclamationmark.triangle",
                    title: String(localized: "rightSidebar.artifacts.loadFailed.title", defaultValue: "Couldn’t Load Artifacts"),
                    message: String(localized: "rightSidebar.artifacts.loadFailed.message", defaultValue: "Check the project folder and try again."),
                    showsAddButton: false
                )
                Button(String(localized: "rightSidebar.artifacts.retry", defaultValue: "Retry")) {
                    Task { await model.refresh() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            if model.rows.isEmpty {
                emptyState(
                    symbol: model.query.isEmpty ? "shippingbox" : "magnifyingglass",
                    title: model.query.isEmpty
                        ? String(localized: "rightSidebar.artifacts.empty.title", defaultValue: "No Artifacts Yet")
                        : String(localized: "rightSidebar.artifacts.noResults.title", defaultValue: "No Matches"),
                    message: model.query.isEmpty
                        ? String(localized: "rightSidebar.artifacts.empty.message", defaultValue: "Agent-created files saved to this project will appear here.")
                        : String(localized: "rightSidebar.artifacts.noResults.message", defaultValue: "Try another filename or text search."),
                    showsAddButton: model.query.isEmpty
                )
            } else {
                artifactRows
            }
        }
    }

    private var artifactRows: some View {
        let actions = ArtifactSidebarRowActions(
            activate: activate,
            toggleExpansion: { model.toggleExpansion(relativePath: $0.relativePath) },
            revealInFinder: { NSWorkspace.shared.activateFileViewerSelecting([$0.fileURL]) },
            copyPath: { copyToPasteboard($0.fileURL.path) },
            copyReference: { copyToPasteboard(".cmux/artifacts/\($0.relativePath)") }
        )
        return ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(model.rows) { row in
                    ArtifactSidebarRowView(snapshot: row, actions: actions)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func emptyState(
        symbol: String,
        title: String,
        message: String,
        showsAddButton: Bool
    ) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .cmuxFont(size: 24, weight: .light)
                .foregroundStyle(.tertiary)
            Text(title)
                .cmuxFont(.headline)
            Text(message)
                .cmuxFont(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 220)
            if showsAddButton {
                Button(String(localized: "rightSidebar.artifacts.add", defaultValue: "Add Artifact…"), action: presentAddPanel)
                    .controlSize(.small)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func activate(_ row: ArtifactSidebarRowSnapshot) {
        if row.isDirectory {
            model.toggleExpansion(relativePath: row.relativePath)
        } else {
            onOpenArtifact(row)
        }
    }

    private func presentAddPanel() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "rightSidebar.artifacts.addPanel.title", defaultValue: "Add to cmux Artifacts")
        panel.message = String(localized: "rightSidebar.artifacts.addPanel.message", defaultValue: "Choose small files to copy into this project’s local artifact store.")
        panel.prompt = String(localized: "rightSidebar.artifacts.addPanel.prompt", defaultValue: "Add")
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await model.addFiles(urls) }
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private var actionFailureBinding: Binding<ArtifactSidebarFailure?> {
        Binding(
            get: { model.actionFailure },
            set: { if $0 == nil { model.clearActionFailure() } }
        )
    }

    private func failureTitle(_ failure: ArtifactSidebarFailure) -> String {
        switch failure {
        case .add:
            return String(localized: "rightSidebar.artifacts.addFailed.title", defaultValue: "Couldn’t Add Artifact")
        case .search:
            return String(localized: "rightSidebar.artifacts.searchFailed.title", defaultValue: "Couldn’t Search Artifacts")
        }
    }

    private func failureMessage(_ failure: ArtifactSidebarFailure) -> String {
        switch failure {
        case .add:
            return String(localized: "rightSidebar.artifacts.addFailed.message", defaultValue: "The file may be unsupported or larger than this project’s capture limit.")
        case .search:
            return String(localized: "rightSidebar.artifacts.searchFailed.message", defaultValue: "Check the artifact folder and try again.")
        }
    }
}

private struct ArtifactSidebarBinding: Equatable {
    let workspaceID: String?
    let workingDirectory: URL?
    let isVisible: Bool
}
