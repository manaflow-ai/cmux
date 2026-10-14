import CmuxNextDesign
import CmuxNextIcons
import SwiftUI

/// The Stashed page (a native OneTab): stashed groups, newest first, each
/// dated and named after its workspace, in the History page's rows and
/// density. A row's click restores that tab; its × or menu deletes it.
struct StashPageView: View {
    @Bindable var model: StashPageModel
    let appearance: HistoryPageAppearance

    private var colors: HistoryPageColors { appearance.colors }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            HairlineDivider(color: colors.separator)
            if model.groups.isEmpty {
                Text(StashStrings.empty)
                    .font(Font(Typography.body)).foregroundStyle(colors.tertiary).multilineTextAlignment(.center)
                    .padding(Metrics.panelInset * 3).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
        }
        .background(colors.background)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Metrics.panelInset * 1.5) {
            HStack(alignment: .firstTextBaseline, spacing: Metrics.panelInset * 1.5) {
                Text(StashStrings.title).font(Font(Typography.title)).foregroundStyle(colors.primary).lineLimit(1)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                if !model.showsImport {
                    Button(StashStrings.importFromOneTab) { model.showImport() }
                        .buttonStyle(.borderless).fixedSize().foregroundStyle(colors.secondary)
                }
            }
            if model.showsImport { importBox }
            if let notice = model.notice {
                Text(notice).font(Font(Typography.caption)).foregroundStyle(colors.secondary).lineLimit(3)
            }
        }
        .padding(Metrics.panelInset * 3)
    }

    /// The inline OneTab paste box: part of the page, never a sheet.
    private var importBox: some View {
        VStack(alignment: .leading, spacing: Metrics.panelInset) {
            Text(StashStrings.importHint).font(Font(Typography.caption)).foregroundStyle(colors.secondary)
            TextEditor(text: $model.importText)
                .font(Font(Typography.body)).foregroundStyle(colors.primary)
                .scrollContentBackground(.hidden).frame(minHeight: 72, maxHeight: 160)
                .padding(Metrics.panelInset / 2)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(colors.separator))
            HStack(spacing: Metrics.panelInset * 1.5) {
                Spacer(minLength: 0)
                Button(StashStrings.cancel) { model.cancelImport() }.buttonStyle(.borderless).foregroundStyle(colors.secondary)
                Button(StashStrings.importAction) { Task { await model.importPasted() } }
                    .buttonStyle(.borderless).foregroundStyle(colors.primary)
                    .disabled(model.importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private var list: some View {
        List {
            ForEach(model.groups) { group in
                Section {
                    ForEach(Array(group.tabs.enumerated()), id: \.offset) { index, tab in
                        row(tab, at: index, in: group)
                    }
                } header: {
                    groupHeader(group)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func row(_ tab: StashedGroup.Tab, at index: Int, in group: StashedGroup) -> some View {
        let entry = HistoryEntry(id: "\(group.id)#\(index)", kind: .page, time: group.createdAt, title: tab.displayTitle,
                                 detail: tab.url, payload: .page(url: tab.url, profile: tab.profile ?? ""))
        return HStack(spacing: Metrics.panelInset) {
            HistoryPageRow(entry: entry, colors: colors)
            Button { Task { await model.delete(group, tab: index) } } label: {
                Icon(.actionClose, size: Metrics.iconSize).foregroundStyle(colors.tertiary)
            }
            .buttonStyle(.plain).help(StashStrings.delete).accessibilityLabel(StashStrings.delete)
        }
        .contentShape(Rectangle())
        .onTapGesture { Task { await model.restore(group, tab: index) } }
        .contextMenu {
            Button(StashStrings.restore) { Task { await model.restore(group, tab: index) } }
            Divider()
            Button(StashStrings.delete, role: .destructive) { Task { await model.delete(group, tab: index) } }
        }
        .listRowBackground(Color.clear)
        .thinScrollers()
    }

    private func groupHeader(_ group: StashedGroup) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.panelInset * 1.5) {
            Text(group.name ?? StashStrings.untitled).font(Font(Typography.header)).foregroundStyle(colors.primary).lineLimit(1)
            Text(group.createdAt.formatted(date: .abbreviated, time: .shortened))
                .font(Font(Typography.caption)).foregroundStyle(colors.tertiary).lineLimit(1)
            Text(group.tabs.count.formatted()).font(Font(Typography.caption)).foregroundStyle(colors.tertiary).monospacedDigit()
            Spacer(minLength: Metrics.panelInset)
            Button(StashStrings.restoreAll) { Task { await model.restore(group) } }
                .buttonStyle(.borderless).foregroundStyle(colors.secondary).fixedSize()
            Button(StashStrings.restoreInNewWorkspace) { Task { await model.restoreInNewWorkspace(group) } }
                .buttonStyle(.borderless).foregroundStyle(colors.secondary).fixedSize()
            Button(StashStrings.deleteGroup) { Task { await model.delete(group) } }
                .buttonStyle(.borderless).foregroundStyle(colors.danger).fixedSize()
        }
        .contextMenu {
            Button(StashStrings.restoreAll) { Task { await model.restore(group) } }
            Button(StashStrings.restoreInNewWorkspace) { Task { await model.restoreInNewWorkspace(group) } }
            Divider()
            Button(StashStrings.deleteGroup, role: .destructive) { Task { await model.delete(group) } }
        }
    }
}
