import AppKit
import SwiftUI

/// Sidebar row for a project group header.
struct GroupHeaderView: View, Equatable {
    let model: GroupRowModel
    let isSelected: Bool
    let isDropTarget: Bool
    let isCustomDragging: Bool
    let onActivate: () -> Void
    let onCustomDragChanged: (CGPoint) -> Void
    let onCustomDragEnded: (CGPoint) -> Void
    let onToggleCollapse: () -> Void
    let onRename: () -> Void
    let onSetColor: (String?) -> Void
    let onPromptCustomColor: () -> Void
    let onUngroup: () -> Void
    let onDeleteGroup: () -> Void
    let colorPalette: [WorkspaceTabColorEntry]

    nonisolated static func == (lhs: GroupHeaderView, rhs: GroupHeaderView) -> Bool {
        lhs.model == rhs.model
            && lhs.isSelected == rhs.isSelected
            && lhs.isDropTarget == rhs.isDropTarget
            && lhs.isCustomDragging == rhs.isCustomDragging
            && lhs.colorPalette == rhs.colorPalette
    }

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let row = HStack(spacing: 6) {
            Image(systemName: "folder.fill")
                .foregroundColor(folderIconColor)
                .font(.system(size: 12))

            Text(model.name)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            Text("\(model.workspaceCount)")
                .font(.caption)
                .foregroundColor(.secondary)

            Button(action: onToggleCollapse) {
                Image(systemName: model.isCollapsed ? "chevron.right" : "chevron.down")
                    .foregroundColor(.secondary)
                    .font(.system(size: 10))
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                model.isCollapsed
                    ? String(localized: "accessibility.group.expand", defaultValue: "Expand")
                    : String(localized: "accessibility.group.collapse", defaultValue: "Collapse")
            )
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(groupBackground)
        .contentShape(Rectangle())
        .scaleEffect(isCustomDragging ? 1.012 : 1.0)
        .shadow(
            color: isCustomDragging ? Color.black.opacity(0.18) : .clear,
            radius: isCustomDragging ? 8 : 0,
            x: 0,
            y: isCustomDragging ? 3 : 0
        )
        .overlay {
            if isCustomDragging {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(cmuxAccentColor().opacity(0.75), lineWidth: 1.25)
            }
        }
        .zIndex(isCustomDragging ? 2 : 0)

        row
            .onTapGesture(perform: onActivate)
            .simultaneousGesture(
                DragGesture(minimumDistance: SidebarInteractionController.dragThreshold, coordinateSpace: .named(sidebarInteractionCoordinateSpace))
                    .onChanged { value in
                        onCustomDragChanged(value.location)
                    }
                    .onEnded { value in
                        onCustomDragEnded(value.location)
                    }
            )
            .accessibilityLabel(accessibilityText)
            .contextMenu {
                Button(String(localized: "contextMenu.renameGroup", defaultValue: "Rename...")) {
                    onRename()
                }

                Menu(String(localized: "contextMenu.groupColor", defaultValue: "Group Color")) {
                    if model.color != nil {
                        Button {
                            onSetColor(nil)
                        } label: {
                            Label(String(localized: "contextMenu.clearColor", defaultValue: "Clear Color"), systemImage: "xmark.circle")
                        }
                    }

                    Button {
                        onPromptCustomColor()
                    } label: {
                        Label(String(localized: "contextMenu.chooseCustomColor", defaultValue: "Choose Custom Color…"), systemImage: "paintpalette")
                    }

                    if !colorPalette.isEmpty {
                        Divider()
                    }

                    ForEach(colorPalette, id: \.id) { entry in
                        Button {
                            onSetColor(entry.hex)
                        } label: {
                            Label {
                                Text(entry.name)
                            } icon: {
                                Image(nsImage: groupColoredCircleImage(color: groupColorSwatchColor(for: entry.hex)))
                            }
                        }
                    }
                }

                Divider()

                Button(String(localized: model.isCollapsed ? "contextMenu.expandGroup" : "contextMenu.collapseGroup",
                              defaultValue: model.isCollapsed ? "Expand" : "Collapse")) {
                    onToggleCollapse()
                }

                Divider()

                Button(String(localized: "contextMenu.ungroup", defaultValue: "Ungroup")) {
                    onUngroup()
                }

                Button(String(localized: "contextMenu.deleteGroup", defaultValue: "Delete Group..."), role: .destructive) {
                    onDeleteGroup()
                }
            }
    }

    @ViewBuilder
    private var groupBackground: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(selectionFillColor)
            .overlay {
                if let hex = model.color, let nsColor = NSColor(hex: hex) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: nsColor).opacity(isSelected ? 0.10 : 0.15))
                }
            }
    }

    private var selectionFillColor: Color {
        if isSelected {
            return Color(nsColor: sidebarSelectedWorkspaceBackgroundNSColor(for: colorScheme))
        }
        if isDropTarget {
            return cmuxAccentColor().opacity(0.22)
        }
        return .clear
    }

    private var folderIconColor: Color {
        if isSelected || isDropTarget {
            return .white
        }
        return .primary
    }

    private var accessibilityText: String {
        let state = model.isCollapsed
            ? String(localized: "accessibility.group.collapsed", defaultValue: "collapsed")
            : String(localized: "accessibility.group.expanded", defaultValue: "expanded")
        return String(
            localized: model.workspaceCount == 1 ? "accessibility.group.label.one" : "accessibility.group.label.other",
            defaultValue: model.workspaceCount == 1
                ? "Project group \(model.name), 1 workspace, \(state)"
                : "Project group \(model.name), \(model.workspaceCount) workspaces, \(state)"
        )
    }

    private func groupColorSwatchColor(for hex: String) -> NSColor {
        WorkspaceTabColorSettings.displayNSColor(
            hex: hex,
            colorScheme: colorScheme,
            forceBright: false
        ) ?? NSColor(hex: hex) ?? .gray
    }

    private func groupColoredCircleImage(color: NSColor) -> NSImage {
        let size = NSSize(width: 12, height: 12)
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        let rect = NSRect(origin: .zero, size: size)
        color.setFill()
        NSBezierPath(ovalIn: rect).fill()

        NSColor.separatorColor.setStroke()
        let strokePath = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
        strokePath.lineWidth = 1
        strokePath.stroke()
        return image
    }
}
