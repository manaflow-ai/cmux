import AppKit
import SwiftUI

/// Renders the file explorer tree in the sidebar.
struct FileExplorerView: View {
    @ObservedObject var state: FileExplorerState
    /// Called when the user single-clicks a file.
    let onFileSelect: (URL) -> Void
    /// Called when the user double-clicks a file (open in external editor).
    let onFileDoubleClick: (URL) -> Void
    /// Called when the user clicks the "sync to cwd" button.
    let onSyncToCwd: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            FileExplorerHeader(
                rootURL: state.rootURL,
                showHidden: $state.showHidden,
                searchQuery: $state.searchQuery,
                onRefresh: { state.refresh() },
                onSyncToCwd: onSyncToCwd
            )

            if state.displayNodes.isEmpty {
                if !state.searchQuery.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 20))
                            .foregroundStyle(.tertiary)
                        Text(String(localized: "fileExplorer.noMatches", defaultValue: "No matches"))
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                } else {
                    FileExplorerEmptyState()
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(state.displayNodes) { node in
                                FileExplorerRow(
                                    node: node,
                                    depth: 0,
                                    state: state,
                                    onFileSelect: onFileSelect,
                                    onFileDoubleClick: onFileDoubleClick
                                )
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .onChange(of: state.scrollToNodeId) { targetId in
                        guard let targetId else { return }
                        withAnimation {
                            proxy.scrollTo(targetId, anchor: .center)
                        }
                        let currentTarget = targetId
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            if state.scrollToNodeId == currentTarget {
                                state.scrollToNodeId = nil
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) {
            if let message = state.revealMessage {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(nsColor: .systemGray).opacity(0.9), in: RoundedRectangle(cornerRadius: 6))
                    .padding(.top, 30)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onAppear {
                        let currentMessage = message
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                            if state.revealMessage == currentMessage {
                                withAnimation { state.revealMessage = nil }
                            }
                        }
                    }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: state.revealMessage)
    }
}

// MARK: - Header

private struct FileExplorerHeader: View {
    let rootURL: URL?
    @Binding var showHidden: Bool
    @Binding var searchQuery: String
    let onRefresh: () -> Void
    let onSyncToCwd: () -> Void
    @State private var showSearchField = false

    var body: some View {
        VStack(spacing: 0) {
        HStack(spacing: 4) {
            Text(String(localized: "fileExplorer.header", defaultValue: "FILES"))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 12)

            Spacer()

            Button(action: onSyncToCwd) {
                Image(systemName: "location")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(String(localized: "fileExplorer.syncToCwd", defaultValue: "Sync to working directory"))

            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(String(localized: "fileExplorer.refresh", defaultValue: "Refresh file tree"))

            Button(action: { withAnimation { showSearchField.toggle() } }) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(showSearchField ? .primary : .secondary)
            }
            .buttonStyle(.plain)
            .help(String(localized: "fileExplorer.search", defaultValue: "Search files"))

            Menu {
                Toggle(String(localized: "fileExplorer.showHidden", defaultValue: "Show Hidden Files"), isOn: $showHidden)
                if let rootURL {
                    Divider()
                    Button(String(localized: "fileExplorer.revealInFinder", defaultValue: "Reveal in Finder")) {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: rootURL.path)
                    }
                    Button(String(localized: "fileExplorer.copyPath", defaultValue: "Copy Path")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(rootURL.path, forType: .string)
                    }
                }
                Divider()
                Text(String(localized: "fileExplorer.gitStatusColors", defaultValue: "Git Status Colors"))
                Button(String(localized: "fileExplorer.status.committed", defaultValue: "⚪ Committed")) {}
                Button(String(localized: "fileExplorer.status.modified", defaultValue: "🟠 Modified")) {}
                Button(String(localized: "fileExplorer.status.added", defaultValue: "🟢 Added")) {}
                Button(String(localized: "fileExplorer.status.deleted", defaultValue: "🔴 Deleted")) {}
                Button(String(localized: "fileExplorer.status.renamed", defaultValue: "🔵 Renamed")) {}
                Button(String(localized: "fileExplorer.status.untracked", defaultValue: "🩶 Untracked")) {}
                Divider()
                Text(String(localized: "fileExplorer.tips", defaultValue: "Tips"))
                Button(String(localized: "fileExplorer.tip.drag", defaultValue: "📁 Drag file → terminal to paste path")) {}
                Button(String(localized: "fileExplorer.tip.search", defaultValue: "🔍 Click magnifying glass to search")) {}
                Button(String(localized: "fileExplorer.tip.reveal", defaultValue: "📍 Click location to reveal open file")) {}
                Button(String(localized: "fileExplorer.tip.edit", defaultValue: "✏️ Click file to edit, Cmd+S to save")) {}
                Button(String(localized: "fileExplorer.tip.sublime", defaultValue: "👆 Double-click to open in Sublime")) {}
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .menuStyle(.borderlessButton)
            .frame(width: 16)
            .padding(.trailing, 8)
        }
        .frame(height: 24)
        .background(Color(nsColor: .separatorColor).opacity(0.1))

        if showSearchField {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                TextField(String(localized: "fileExplorer.searchPlaceholder", defaultValue: "Search files..."), text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                if !searchQuery.isEmpty {
                    Button(action: { searchQuery = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(Color(nsColor: .separatorColor).opacity(0.05))
        }
        }
        .onChange(of: showSearchField) { visible in
            if !visible { searchQuery = "" }
        }
    }
}

// MARK: - Empty state

private struct FileExplorerEmptyState: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "folder")
                .font(.system(size: 20))
                .foregroundStyle(.tertiary)
            Text(String(localized: "fileExplorer.noFiles", defaultValue: "No files"))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

// MARK: - Row (recursive)

private struct FileExplorerRow: View {
    let node: FileExplorerNode
    let depth: Int
    @ObservedObject var state: FileExplorerState
    let onFileSelect: (URL) -> Void
    let onFileDoubleClick: (URL) -> Void

    @State private var isHovered = false

    private let indentWidth: CGFloat = 16
    private let rowHeight: CGFloat = 22

    private var isCurrentFile: Bool {
        !node.isDirectory && node.url.path == state.currentEditingFilePath
    }

    private var rowBackground: Color {
        if isCurrentFile {
            return Color.accentColor.opacity(isHovered ? 0.25 : 0.15)
        }
        return isHovered ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.15) : .clear
    }

    /// File name color based on git status.
    /// Checks the node's own status and inherits from parent directories
    /// (e.g., files inside an untracked directory are also untracked).
    private var nameColor: Color {
        if let status = state.gitStatusMap[node.id] {
            return colorForStatus(status)
        }
        // Check parent directories — untracked dirs mean all children are untracked
        var components = node.id.split(separator: "/")
        while !components.isEmpty {
            components.removeLast()
            let parentPath = "/" + components.joined(separator: "/")
            if let parentStatus = state.gitStatusMap[parentPath] {
                return colorForStatus(parentStatus)
            }
        }
        return .primary
    }

    private func colorForStatus(_ status: GitFileStatus) -> Color {
        switch status {
        case .modified: return .orange
        case .added: return .green
        case .deleted: return .red
        case .renamed: return .blue
        case .untracked: return Color(nsColor: NSColor(white: 0.5, alpha: 1.0))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The row itself
            HStack(spacing: 4) {
                // Indent
                Spacer()
                    .frame(width: CGFloat(depth) * indentWidth + 8)

                // Disclosure triangle for directories
                if node.isDirectory {
                    Image(systemName: node.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                } else {
                    Spacer()
                        .frame(width: 10)
                }

                // File/folder icon
                Image(systemName: node.iconName)
                    .font(.system(size: 11))
                    .foregroundStyle(node.isDirectory ? .blue : .secondary)
                    .frame(width: 14)

                // Name (colored by git status)
                Text(node.name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(nameColor)

                Spacer()
            }
            .frame(height: rowHeight)
            .contentShape(Rectangle())
            .background(rowBackground)
            .onDrag {
                // Drag file URL to terminal — inserts shell-escaped path
                NSItemProvider(object: node.url as NSURL)
            }
            .onHover { hovering in
                isHovered = hovering
            }
            .onTapGesture(count: 2) {
                if !node.isDirectory {
                    onFileDoubleClick(node.url)
                }
            }
            .onTapGesture(count: 1) {
                if node.isDirectory {
                    state.toggleExpanded(nodeId: node.id)
                } else {
                    onFileSelect(node.url)
                }
            }
            .id(node.id)
            .contextMenu {
                FileExplorerContextMenu(node: node)
            }

            // Recursively render children if expanded
            if node.isDirectory, node.isExpanded, let children = node.children {
                ForEach(children) { child in
                    FileExplorerRow(
                        node: child,
                        depth: depth + 1,
                        state: state,
                        onFileSelect: onFileSelect,
                        onFileDoubleClick: onFileDoubleClick
                    )
                }
            }
        }
    }
}

// MARK: - Context menu

private struct FileExplorerContextMenu: View {
    let node: FileExplorerNode

    var body: some View {
        if !node.isDirectory {
            Button(String(localized: "fileExplorer.openInDefaultEditor", defaultValue: "Open in Default Editor")) {
                NSWorkspace.shared.open(node.url)
            }
        }
        Button(String(localized: "fileExplorer.revealInFinder", defaultValue: "Reveal in Finder")) {
            NSWorkspace.shared.activateFileViewerSelecting([node.url])
        }
        Divider()
        Button(String(localized: "fileExplorer.copyPath", defaultValue: "Copy Path")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(node.url.path, forType: .string)
        }
        Button(String(localized: "fileExplorer.copyRelativePath", defaultValue: "Copy Relative Path")) {
            let name = node.id.hasPrefix("/") ? String(node.id.dropFirst()) : node.id
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(name, forType: .string)
        }
    }
}

// MARK: - Sidebar divider (draggable)

/// A horizontal draggable divider between the tab list and file explorer.
struct FileExplorerDivider: View {
    @Binding var position: CGFloat
    let totalHeight: CGFloat
    var minFraction: CGFloat = 0.1
    var maxFraction: CGFloat = 0.8
    private let handleHeight: CGFloat = 6

    @State private var isDragging = false
    @State private var isHovered = false
    @State private var dragStartPosition: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(isDragging || isHovered
                ? Color.accentColor.opacity(0.5)
                : Color(nsColor: .separatorColor))
            .frame(height: isDragging || isHovered ? 2 : 1)
            .frame(maxWidth: .infinity)
            .padding(.vertical, (handleHeight - 1) / 2)
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovered = hovering
                if hovering {
                    NSCursor.resizeUpDown.push()
                } else if !isDragging {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if !isDragging {
                            dragStartPosition = position
                            isDragging = true
                        }
                        let newPosition = dragStartPosition + (value.translation.height / totalHeight)
                        position = min(maxFraction, max(minFraction, newPosition))
                    }
                    .onEnded { _ in
                        isDragging = false
                        if !isHovered {
                            NSCursor.pop()
                        }
                    }
            )
            .accessibilityIdentifier("FileExplorerDivider")
    }
}
