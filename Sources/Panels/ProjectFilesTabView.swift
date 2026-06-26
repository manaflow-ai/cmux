import CmuxFoundation
import AppKit
import CMUXProjectModel
import SwiftUI

/// Files tab inside ``ProjectPanelView``.
///
/// Renders the merged group tree from every ``ProjectModule`` in the loaded
/// ``ProjectModel`` on the left, and a detail strip showing target
/// memberships and on-disk path for the selected file on the right.
private struct FlattenedRow: Identifiable {
    enum Kind { case group(ProjectGroup, isExpanded: Bool); case file(ProjectFileNode) }
    let id: ProjectNodeID
    let depth: Int
    let module: ProjectModule
    let kind: Kind
}

struct ProjectFilesTabView: View {
    @ObservedObject var panel: ProjectPanel
    let model: ProjectModel

    var body: some View {
        let rows = flattenedRows
        VStack(alignment: .leading, spacing: 0) {
            filterBar(rowCount: rows.count)
            Divider()
            if panel.selectedFilePath != nil {
                HSplitView {
                    navigator(rows: rows)
                        .frame(minWidth: 280, idealWidth: 360, maxHeight: .infinity)
                    detail
                        .frame(minWidth: 240, maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                navigator(rows: rows)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private func filterBar(rowCount: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Filter files (e.g. AppDelegate)", text: $panel.filesSearchText)
                .textFieldStyle(.plain)
                .cmuxFont(size: 12)
            if !panel.filesSearchText.isEmpty {
                Button {
                    panel.filesSearchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Text("\(rowCount)")
                .cmuxFont(size: 11)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.4))
    }

    @ViewBuilder
    private func navigator(rows: [FlattenedRow]) -> some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows, id: \.id) { row in
                    renderRow(row)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(NSColor.controlBackgroundColor).opacity(0.45))
    }

    private var flattenedRows: [FlattenedRow] {
        var out: [FlattenedRow] = []
        let filter = panel.filesSearchText.lowercased()
        for module in model.modules {
            walk(node: .group(module.rootGroup), depth: 0, module: module, filter: filter, out: &out)
        }
        return out
    }

    private func walk(
        node: ProjectNodeKind,
        depth: Int,
        module: ProjectModule,
        filter: String,
        out: inout [FlattenedRow]
    ) {
        switch node {
        case let .group(group):
            if !filter.isEmpty {
                let matches = Self.collectMatchingFiles(in: group, filter: filter)
                if matches.isEmpty { return }
                let presentation = Self.presentationGroup(for: group, fallbackName: module.displayName)
                out.append(FlattenedRow(
                    id: group.id,
                    depth: depth,
                    module: module,
                    kind: .group(presentation, isExpanded: true)
                ))
                for match in matches {
                    out.append(FlattenedRow(
                        id: match.id,
                        depth: depth + 1,
                        module: module,
                        kind: .file(match)
                    ))
                }
                return
            }
            let isExpanded = !panel.collapsedNodeIDs.contains(group.id)
            let presentation = Self.presentationGroup(for: group, fallbackName: module.displayName)
            out.append(FlattenedRow(
                id: group.id,
                depth: depth,
                module: module,
                kind: .group(presentation, isExpanded: isExpanded)
            ))
            if isExpanded {
                for child in group.children {
                    walk(node: child, depth: depth + 1, module: module, filter: filter, out: &out)
                }
            }
        case let .file(file):
            out.append(FlattenedRow(
                id: file.id,
                depth: depth,
                module: module,
                kind: .file(file)
            ))
        }
    }

    private static func presentationGroup(for group: ProjectGroup, fallbackName: String) -> ProjectGroup {
        if group.displayName.isEmpty || group.displayName == "(group)" {
            return ProjectGroup(
                id: group.id,
                displayName: fallbackName,
                resolvedPath: group.resolvedPath,
                style: group.style,
                children: group.children
            )
        }
        return group
    }

    private static func collectMatchingFiles(in group: ProjectGroup, filter: String) -> [ProjectFileNode] {
        var out: [ProjectFileNode] = []
        for child in group.children {
            switch child {
            case let .file(file):
                // `searchName` is the precomputed lowercased name; `filter` is
                // already lowercased by the caller, so this stays a
                // case-insensitive substring match with zero per-keystroke
                // string allocations.
                if file.searchName.contains(filter) {
                    out.append(file)
                }
            case let .group(subgroup):
                out.append(contentsOf: collectMatchingFiles(in: subgroup, filter: filter))
            }
        }
        return out
    }

    @ViewBuilder
    private func renderRow(_ row: FlattenedRow) -> some View {
        switch row.kind {
        case let .group(group, isExpanded):
            ProjectFilesGroupRow(
                group: group,
                depth: row.depth,
                isExpanded: isExpanded,
                onToggle: {
                    if isExpanded {
                        panel.collapsedNodeIDs.insert(group.id)
                    } else {
                        panel.collapsedNodeIDs.remove(group.id)
                    }
                }
            )
        case let .file(file):
            ProjectFilesFileRow(
                file: file,
                depth: row.depth,
                module: row.module,
                isSelected: panel.selectedFilePath == file.resolvedPath?.path,
                onSelect: {
                    panel.selectedFilePath = file.resolvedPath?.path
                }
            )
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let path = panel.selectedFilePath,
           let file = findFile(byPath: path),
           let module = findModule(forFilePath: path) {
            ProjectFilesDetailStrip(file: file, module: module)
        } else {
            ProjectEmptyDetailView(
                systemImage: "doc.text.magnifyingglass",
                title: "Select a file",
                hint: "Pick any file in the tree to see its target memberships and on-disk path."
            )
        }
    }

    private func findFile(byPath path: String) -> ProjectFileNode? {
        for module in model.modules {
            if let found = ProjectFilesTabView.findFile(in: module.rootGroup, path: path) {
                return found
            }
        }
        return nil
    }

    private func findModule(forFilePath path: String) -> ProjectModule? {
        for module in model.modules {
            if ProjectFilesTabView.findFile(in: module.rootGroup, path: path) != nil {
                return module
            }
        }
        return nil
    }

    private static func findFile(in group: ProjectGroup, path: String) -> ProjectFileNode? {
        for child in group.children {
            switch child {
            case let .file(file):
                if file.resolvedPath?.path == path {
                    return file
                }
            case let .group(subgroup):
                if let nested = findFile(in: subgroup, path: path) {
                    return nested
                }
            }
        }
        return nil
    }
}

private struct ProjectFilesGroupRow: View {
    let group: ProjectGroup
    let depth: Int
    let isExpanded: Bool
    let onToggle: () -> Void
    @Environment(\.cmuxGlobalFontMagnificationPercent) private var globalFontPercent

    var body: some View {
        let scale = GlobalFontMagnification.scale(for: globalFontPercent)
        let chevronWidth = max(1, 12 * scale)
        let symbolFrame = max(1, 14 * scale)
        Button(action: onToggle) {
            HStack(spacing: 4) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .cmuxFont(size: 9, weight: .semibold)
                    .frame(width: chevronWidth)
                    .foregroundStyle(.secondary)
                Image(systemName: glyph(for: group.style))
                    .cmuxFont(size: 12)
                    .imageScale(.small)
                    .frame(width: symbolFrame, height: symbolFrame)
                    .foregroundStyle(.secondary)
                Text(group.displayName)
                    .cmuxFont(size: 12)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(depth) * 14 + 6)
            .padding(.vertical, 2)
            .padding(.trailing, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func glyph(for style: ProjectGroupStyle) -> String {
        switch style {
        case .logical: return "folder"
        case .folderRef: return "folder.fill"
        case .variant: return "globe"
        case .synchronized: return "folder.badge.gearshape"
        }
    }
}

private struct ProjectFilesFileRow: View {
    let file: ProjectFileNode
    let depth: Int
    let module: ProjectModule
    let isSelected: Bool
    let onSelect: () -> Void
    @Environment(\.cmuxGlobalFontMagnificationPercent) private var globalFontPercent

    var body: some View {
        let scale = GlobalFontMagnification.scale(for: globalFontPercent)
        let spacerWidth = max(1, 12 * scale)
        let symbolFrame = max(1, 14 * scale)
        Button(action: onSelect) {
            HStack(spacing: 4) {
                Spacer().frame(width: spacerWidth)
                Image(systemName: glyph(for: file.fileType))
                    .cmuxFont(size: 12)
                    .imageScale(.small)
                    .frame(width: symbolFrame, height: symbolFrame)
                    .foregroundStyle(file.existsOnDisk ? Color.secondary : Color.orange)
                Text(file.displayName)
                    .cmuxFont(size: 12)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .strikethrough(!file.existsOnDisk)
                Spacer(minLength: 6)
                if !file.memberships.isEmpty {
                    HStack(spacing: 2) {
                        ForEach(memberships, id: \.targetID) { membership in
                            Text(targetLabel(for: membership.targetID))
                                .cmuxFont(size: 9, weight: .medium)
                                .lineLimit(1)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Color.accentColor.opacity(0.15))
                                )
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }
            .padding(.leading, CGFloat(depth) * 14 + 6)
            .padding(.vertical, 2)
            .padding(.trailing, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.accentColor.opacity(0.18) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var memberships: [TargetMembership] { file.memberships }

    private func targetLabel(for id: TargetID) -> String {
        guard let target = module.target(for: id) else {
            return String(id.rawValue.prefix(6))
        }
        return target.displayName
    }

    private func glyph(for fileType: String?) -> String {
        guard let fileType else { return "doc" }
        if fileType.contains("swift") { return "swift" }
        if fileType.contains("xcconfig") { return "doc.text" }
        if fileType.contains("plist") { return "list.bullet.rectangle" }
        if fileType.contains("asset") || fileType.contains("xcassets") { return "paintpalette" }
        if fileType.contains("storyboard") || fileType.contains("xib") { return "rectangle.3.group" }
        if fileType.contains("markdown") || fileType.contains("text") { return "doc.text" }
        if fileType.contains("entitlement") { return "lock.shield" }
        if fileType.contains("xcstrings") { return "globe" }
        return "doc"
    }
}

private struct ProjectFilesDetailStrip: View {
    let file: ProjectFileNode
    let module: ProjectModule

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "doc.text")
                Text(file.displayName)
                    .cmuxFont(size: 13, weight: .semibold)
                Spacer()
            }
            if let path = file.resolvedPath?.path {
                row(label: "Path", value: path)
            }
            if let type = file.fileType {
                row(label: "Type", value: type)
            }
            row(label: "On disk", value: file.existsOnDisk ? "Yes" : "Missing")
            if !file.memberships.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Targets")
                        .cmuxFont(size: 11, weight: .semibold)
                        .foregroundStyle(.secondary)
                    ForEach(file.memberships, id: \.targetID) { membership in
                        membershipRow(for: membership)
                    }
                }
            }
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func row(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .cmuxFont(size: 11, weight: .semibold)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .cmuxFont(size: 11, design: .monospaced)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func membershipRow(for membership: TargetMembership) -> some View {
        let target = module.target(for: membership.targetID)
        HStack(spacing: 6) {
            Image(systemName: "checkmark.square")
                .foregroundStyle(Color.accentColor)
            Text(target?.displayName ?? String(membership.targetID.rawValue.prefix(8)))
                .cmuxFont(size: 12)
            Text("· \(membership.role.rawValue)")
                .cmuxFont(size: 11)
                .foregroundStyle(.secondary)
            if !membership.compilerFlags.isEmpty {
                Text("flags: \(membership.compilerFlags.joined(separator: " "))")
                    .cmuxFont(size: 10, design: .monospaced)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}
