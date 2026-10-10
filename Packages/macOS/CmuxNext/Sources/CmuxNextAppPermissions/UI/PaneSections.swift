import SwiftUI

/// Granted folders: name, write mark, remove; Add Folder… opens the host
/// file panel (the app never names a path).
struct FoldersSection: View {
    var record: AppPermissionRecord
    var add: @MainActor () -> Void
    var remove: @MainActor (String) -> Void
    @Environment(\.permissionColors) private var colors

    /// Folders reach the app only under Standard.
    private var canAdd: Bool { record.profile == .standard && !record.grant.disabled }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                SectionHeading(text: AppPermissionsStrings.folders)
                Spacer()
                Button(AppPermissionsStrings.addFolder, action: add)
                    .buttonStyle(PermissionButtonStyle(kind: .quiet))
                    .font(colors.caption)
                    .padding(.top, 8)
                    .disabled(!canAdd)
                    .opacity(canAdd ? 1 : 0.4)
            }
            if record.grant.fileRoots.isEmpty {
                Text(AppPermissionsStrings.noFolders).font(colors.caption).foregroundStyle(colors.tertiary)
            }
            ForEach(record.grant.fileRoots) { root in
                HStack(spacing: 8) {
                    Image(systemName: root.kind == .workspaceFolder ? "square.stack" : "folder")
                        .font(.system(size: 11)).foregroundStyle(colors.secondary).frame(width: 14)
                    Text(root.label).font(colors.body).foregroundStyle(colors.text).lineLimit(1)
                    if root.writable {
                        Text(AppPermissionsStrings.writable).font(colors.caption).foregroundStyle(colors.warning)
                    }
                    Spacer()
                    Button { remove(root.id) } label: {
                        Image(systemName: "minus.circle").font(.system(size: 11)).foregroundStyle(colors.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(AppPermissionsStrings.remove))
                }
                .padding(.vertical, 2)
                .opacity(record.profile == .standard ? 1 : 0.45)
            }
        }
    }
}

/// Workspaces, rooms and machines the app may touch (nil = all).
struct ReachSection: View {
    var selectors: AppResourceSelectors
    var source: any AppPermissionsDataSource
    var set: @MainActor (AppResourceSelectors) -> Void
    @Environment(\.permissionColors) private var colors

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionHeading(text: AppPermissionsStrings.reach)
            HStack(spacing: 14) {
                menu(AppPermissionsStrings.allWorkspaces, symbol: "rectangle.stack", options: source.workspaces, current: selectors.workspaces) {
                    var next = selectors
                    next.workspaces = $0
                    set(next)
                }
                menu(AppPermissionsStrings.allRooms, symbol: "person.2", options: source.rooms, current: selectors.rooms) {
                    var next = selectors
                    next.rooms = $0
                    set(next)
                }
                menu(AppPermissionsStrings.allMachines, symbol: "desktopcomputer", options: source.machines, current: selectors.machines) {
                    var next = selectors
                    next.machines = $0
                    set(next)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func menu(_ all: String, symbol: String, options: [AppResourceOption], current: Set<String>?,
                      apply: @escaping @MainActor (Set<String>?) -> Void) -> some View {
        Menu {
            Button(all) { apply(nil) }
            Divider()
            ForEach(options) { option in
                let on = current?.contains(option.id) ?? false
                Button {
                    var next = current ?? []
                    if on { next.remove(option.id) } else { next.insert(option.id) }
                    apply(next)
                } label: {
                    if on { Label(option.name, systemImage: "checkmark") } else { Text(option.name) }
                }
            }
        } label: {
            Label(current.map { AppPermissionsStrings.selectedCount($0.count) } ?? all, systemImage: symbol)
                .font(colors.caption)
                .foregroundStyle(current == nil ? colors.secondary : colors.text)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

/// The last calls by scope: op, result, time (never params).
struct ActivitySection: View {
    var entries: [AppActivityEntry]
    @Environment(\.permissionColors) private var colors

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            SectionHeading(text: AppPermissionsStrings.activity)
            if entries.isEmpty {
                Text(AppPermissionsStrings.noActivity).font(colors.caption).foregroundStyle(colors.tertiary)
            }
            ForEach(entries.prefix(6)) { entry in
                HStack(spacing: 8) {
                    Circle().fill(color(entry.result)).frame(width: 5, height: 5)
                    Text(verbatim: entry.op).font(.system(size: 11, design: .monospaced)).foregroundStyle(colors.secondary).lineLimit(1)
                    Text(AppPermissionsStrings.result(entry.result)).font(colors.caption).foregroundStyle(colors.tertiary)
                    Spacer()
                    Text(entry.time.formatted(.relative(presentation: .named))).font(colors.caption).foregroundStyle(colors.tertiary).lineLimit(1)
                }
            }
        }
    }

    private func color(_ result: AppActivityResult) -> Color {
        switch result {
        case .allowed: colors.tertiary
        case .asked: colors.warning
        case .refused: colors.danger
        }
    }
}
