import Foundation
import SwiftUI
import AppKit

struct FileTreeSidebar: View {
    @ObservedObject var model: FileTreeModel
    @ObservedObject var workspace: Workspace
    let onComposePath: (String) -> Void

    @State private var selectedFilePath: String?

    var body: some View {
        VStack(spacing: 0) {
            // Header with directory name and controls
            HStack(spacing: 6) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                Text(directoryBasename)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundColor(.secondary)

                Spacer()

                Button {
                    model.toggleHiddenFiles()
                } label: {
                    Image(systemName: model.showHiddenFiles ? "eye" : "eye.slash")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help(model.showHiddenFiles ? "Hide hidden files" : "Show hidden files")

                Button {
                    model.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Refresh")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider()

            GeometryReader { proxy in
                ScrollView {
                    if model.rootNodes.isEmpty {
                        Text("Empty directory")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 24)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(model.rootNodes) { node in
                                FileTreeRow(
                                    node: node,
                                    depth: 0,
                                    model: model,
                                    selectedFilePath: selectedFilePath,
                                    onSelect: { path in
                                        selectedFilePath = path
                                    },
                                    onComposePath: onComposePath
                                )
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                .modifier(ClearScrollBackground())
            }
        }
        .onChange(of: workspace.currentDirectory) { newDirectory in
            let trimmed = newDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && trimmed != model.rootPath {
                model.loadDirectory(trimmed)
                selectedFilePath = nil
            }
        }
        .onAppear {
            let dir = workspace.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            if !dir.isEmpty && dir != model.rootPath {
                model.loadDirectory(dir)
            }
        }
    }

    private var directoryBasename: String {
        let dir = workspace.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dir.isEmpty else { return "No directory" }
        return (dir as NSString).lastPathComponent
    }
}
