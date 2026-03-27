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
                        Text("No matches")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                } else {
                    FileExplorerEmptyState()
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
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
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            Text("FILES")
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
            .help("Sync to working directory")

            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Refresh file tree")

            Button(action: { withAnimation { showSearchField.toggle() } }) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(showSearchField ? .primary : .secondary)
            }
            .buttonStyle(.plain)
            .help("Search files")

            Menu {
                Toggle("Show Hidden Files", isOn: $showHidden)
                if let rootURL {
                    Divider()
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: rootURL.path)
                    }
                    Button("Copy Path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(rootURL.path, forType: .string)
                    }
                }
                Divider()
                Text("Git Status Colors")
                Button("⚪ Committed") {}
                Button("🟠 Modified") {}
                Button("🟢 Added") {}
                Button("🔴 Deleted") {}
                Button("🔵 Renamed") {}
                Button("🩶 Untracked") {}
                Divider()
                Text("Tips")
                Button("📁 Drag file → terminal to paste path") {}
                Button("🔍 Click magnifying glass to search") {}
                Button("📍 Click location to reveal open file") {}
                Button("✏️ Click file to edit, Cmd+S to save") {}
                Button("👆 Double-click to open in Sublime") {}
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
                TextField("Search files...", text: $searchQuery)
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
            Text("No files")
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
            Button("Open in Default Editor") {
                NSWorkspace.shared.open(node.url)
            }
        }
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([node.url])
        }
        Divider()
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(node.url.path, forType: .string)
        }
        Button("Copy Relative Path") {
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

    private let minFraction: CGFloat = 0.2
    private let maxFraction: CGFloat = 0.8
    private let handleHeight: CGFloat = 6

    @State private var isDragging = false
    @State private var isHovered = false

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
                        isDragging = true
                        let newPosition = position + (value.translation.height / totalHeight)
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
