import Foundation
import SwiftUI
import AppKit

struct FileTreeSidebar: View {
    @ObservedObject var model: FileTreeModel
    @ObservedObject var workspace: Workspace
    let onComposePath: (String) -> Void

    @State private var selectedFilePath: String?

    private let trafficLightPadding: CGFloat = 28

    var body: some View {
        VStack(spacing: 0) {
            // Space for traffic lights / titlebar controls
            Spacer()
                .frame(height: trafficLightPadding)

            // Header with directory name
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
        .onChange(of: workspace.currentDirectory) {
            let trimmed = workspace.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                model.clearDirectory()
                selectedFilePath = nil
            } else if trimmed != model.rootPath {
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
