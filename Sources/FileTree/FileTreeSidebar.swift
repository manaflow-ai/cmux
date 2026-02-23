import Foundation
import SwiftUI
import AppKit

struct FileTreeSidebar: View {
    @ObservedObject var model: FileTreeModel
    @ObservedObject var workspace: Workspace
    let onFileAction: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            // File tree content
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
                                    onFileAction: onFileAction
                                )
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                .modifier(ClearScrollBackground())
            }
        }
        .ignoresSafeArea()
        .onChange(of: workspace.currentDirectory) { newDirectory in
            let trimmed = newDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && trimmed != model.rootPath {
                model.loadDirectory(trimmed)
            }
        }
        .onAppear {
            let dir = workspace.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            if !dir.isEmpty && dir != model.rootPath {
                model.loadDirectory(dir)
            }
        }
    }


}
