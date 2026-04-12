import SwiftUI
import AppKit

/// File explorer tree view shown in the sidebar when the user selects the files mode.
struct FileExplorerView: View {
    @ObservedObject var model: FileExplorerModel
    let onOpenInTerminal: ((URL) -> Void)?

    private let rowHeight: CGFloat = 22
    private let indentWidth: CGFloat = 16

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            headerRow
            fileTree
        }
    }

    // MARK: - Search bar

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            FileExplorerSearchField(
                text: $model.searchQuery,
                placeholder: String(localized: "fileExplorer.search.placeholder", defaultValue: "Filter files…")
            )
            .frame(height: 18)
            if !model.searchQuery.isEmpty {
                Button {
                    model.searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.3))
        .cornerRadius(6)
        .padding(.horizontal, 8)
        .padding(.top, 4)
        .padding(.bottom, 2)
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(spacing: 4) {
            Text(model.rootDisplayName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer()
            Button {
                model.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help(String(localized: "fileExplorer.refresh", defaultValue: "Refresh"))

            Button {
                model.showHiddenFiles.toggle()
            } label: {
                Image(systemName: model.showHiddenFiles ? "eye" : "eye.slash")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help(
                model.showHiddenFiles
                    ? String(localized: "fileExplorer.hideHidden", defaultValue: "Hide Hidden Files")
                    : String(localized: "fileExplorer.showHidden", defaultValue: "Show Hidden Files")
            )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    // MARK: - File tree

    private var fileTree: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if model.flatDisplayItems.isEmpty {
                    emptyState
                } else {
                    ForEach(model.flatDisplayItems) { entry in
                        FileExplorerRowView(
                            item: entry.item,
                            depth: entry.depth,
                            isExpanded: model.isExpanded(entry.item),
                            indentWidth: indentWidth,
                            rowHeight: rowHeight,
                            onToggle: { model.toggleExpansion(entry.item) },
                            onOpenFile: { NSWorkspace.shared.open(entry.item.url) }
                        )
                        .contextMenu {
                            fileExplorerContextMenu(for: entry.item)
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 24))
                .foregroundColor(.secondary.opacity(0.5))
            Text(model.searchQuery.isEmpty
                ? String(localized: "fileExplorer.empty", defaultValue: "No files")
                : String(localized: "fileExplorer.noResults", defaultValue: "No matching files"))
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    // MARK: - Context menu

    @ViewBuilder
    private func fileExplorerContextMenu(for item: FileExplorerItem) -> some View {
        Button {
            copyToPasteboard(item.url.path)
        } label: {
            Text(String(localized: "fileExplorer.contextMenu.copyPath", defaultValue: "Copy Path"))
        }
        Button {
            copyToPasteboard(item.relativePath(from: model.rootURL))
        } label: {
            Text(String(localized: "fileExplorer.contextMenu.copyRelativePath", defaultValue: "Copy Relative Path"))
        }
        Divider()
        Button {
            NSWorkspace.shared.selectFile(item.url.path, inFileViewerRootedAtPath: item.url.deletingLastPathComponent().path)
        } label: {
            Text(String(localized: "fileExplorer.contextMenu.revealInFinder", defaultValue: "Reveal in Finder"))
        }
        if item.isDirectory, let onOpenInTerminal {
            Button { onOpenInTerminal(item.url) } label: {
                Text(String(localized: "fileExplorer.contextMenu.openInTerminal", defaultValue: "Open in Terminal"))
            }
        }
    }

    private func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

// MARK: - Row view

private struct FileExplorerRowView: View {
    let item: FileExplorerItem
    let depth: Int
    let isExpanded: Bool
    let indentWidth: CGFloat
    let rowHeight: CGFloat
    let onToggle: () -> Void
    let onOpenFile: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 4) {
            if item.isDirectory {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 12)
            } else {
                Spacer().frame(width: 12)
            }

            Image(systemName: item.iconName)
                .font(.system(size: 12))
                .foregroundColor(item.isDirectory ? .accentColor : .secondary)
                .frame(width: 16)

            Text(item.name)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundColor(.primary)

            Spacer()
        }
        .padding(.leading, CGFloat(depth) * indentWidth + 8)
        .padding(.trailing, 8)
        .frame(height: rowHeight)
        .background(isHovering ? Color.primary.opacity(0.06) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            if item.isDirectory { onToggle() } else { onOpenFile() }
        }
        .onHover { isHovering = $0 }
    }
}

// MARK: - AppKit search field

private struct FileExplorerSearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: FileExplorerSearchField
        var isProgrammatic = false

        init(parent: FileExplorerSearchField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            guard !isProgrammatic, let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> FileExplorerNativeTextField {
        let field = FileExplorerNativeTextField(frame: .zero)
        field.font = .systemFont(ofSize: 12)
        field.placeholderString = placeholder
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.lineBreakMode = .byTruncatingTail
        field.cell?.sendsActionOnEndEditing = false
        field.delegate = context.coordinator
        field.stringValue = text
        field.setAccessibilityIdentifier("FileExplorerSearchField")
        return field
    }

    func updateNSView(_ nsView: FileExplorerNativeTextField, context: Context) {
        if nsView.stringValue != text {
            context.coordinator.isProgrammatic = true
            nsView.stringValue = text
            context.coordinator.isProgrammatic = false
        }
    }
}

/// Custom NSTextField that claims first responder on mouse down, preventing
/// the Ghostty terminal surface from intercepting keyboard events.
final class FileExplorerNativeTextField: NSTextField {
    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        if let window, window.firstResponder !== currentEditor() {
            window.makeFirstResponder(self)
        }
        super.mouseDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { currentEditor()?.selectAll(nil) }
        return result
    }
}
