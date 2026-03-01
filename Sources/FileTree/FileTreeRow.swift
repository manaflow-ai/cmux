import Foundation
import SwiftUI
import AppKit

struct FileTreeRow: View {
    let node: FileTreeNode
    let depth: Int
    @ObservedObject var model: FileTreeModel
    let selectedFilePath: String?
    let onSelect: (String) -> Void
    let onComposePath: (String) -> Void

    @State private var isHovered: Bool = false
    @State private var flashOpacity: Double = 0

    var body: some View {
        VStack(spacing: 0) {
            Button {
                let isCmd = NSApp.currentEvent?.modifierFlags.contains(.command) == true

                if isCmd {
                    onComposePath(node.path)
                    withAnimation(.easeOut(duration: 0.15)) {
                        flashOpacity = 0.3
                    }
                    withAnimation(.easeOut(duration: 0.3).delay(0.15)) {
                        flashOpacity = 0
                    }
                } else if node.isDirectory {
                    model.toggleExpand(node)
                } else {
                    onSelect(node.path)
                }
            } label: {
                HStack(spacing: 4) {
                    if node.isDirectory {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary)
                            .rotationEffect(.degrees(node.isExpanded ? 90 : 0))
                            .animation(.easeInOut(duration: 0.15), value: node.isExpanded)
                            .frame(width: 12)
                    } else {
                        Spacer()
                            .frame(width: 12)
                    }

                    Image(systemName: node.iconName)
                        .font(.system(size: 12))
                        .foregroundColor(node.isDirectory ? .accentColor : .secondary)
                        .frame(width: 16)

                    Text(node.name)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundColor(.primary)

                    Spacer()
                }
                .padding(.leading, CGFloat(16 * depth))
                .padding(.trailing, 8)
                .padding(.vertical, 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(backgroundColor)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.accentColor.opacity(flashOpacity))
                )
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                isHovered = hovering
            }
            .contextMenu {
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(node.path, forType: .string)
                }
                Button("Reveal in Finder") {
                    NSWorkspace.shared.selectFile(node.path, inFileViewerRootedAtPath: "")
                }
                Button("Open in Default App") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: node.path))
                }
                Divider()
                Button("Insert Path to Terminal") {
                    onComposePath(node.path)
                }
            }

            if node.isDirectory && node.isExpanded, let children = node.children {
                ForEach(children) { child in
                    FileTreeRow(
                        node: child,
                        depth: depth + 1,
                        model: model,
                        selectedFilePath: selectedFilePath,
                        onSelect: onSelect,
                        onComposePath: onComposePath
                    )
                }
            }
        }
    }

    private var backgroundColor: Color {
        if selectedFilePath == node.path {
            return Color.accentColor.opacity(0.15)
        }
        if isHovered {
            return Color.primary.opacity(0.05)
        }
        return Color.clear
    }
}
