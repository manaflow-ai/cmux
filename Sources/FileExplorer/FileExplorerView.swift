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
                onRefresh: { state.refresh() },
                onSyncToCwd: onSyncToCwd
            )

            if state.rootNodes.isEmpty {
                FileExplorerEmptyState()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(state.rootNodes) { node in
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
    let onRefresh: () -> Void
    let onSyncToCwd: () -> Void

    var body: some View {
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

                // Name
                Text(node.name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.primary)

                Spacer()
            }
            .frame(height: rowHeight)
            .contentShape(Rectangle())
            .background(isHovered ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.15) : .clear)
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
