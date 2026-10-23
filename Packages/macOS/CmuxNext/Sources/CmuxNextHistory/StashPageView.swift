import AppKit
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextIcons
import SwiftUI

/// The Stashed page (a native OneTab): stashed groups, newest first, each
/// dated and named after its workspace, one compact line per page. A row's
/// click restores that tab; its × or menu deletes it. The page is disabled
/// while an op is in flight; deletes offer Undo in a toast.
struct StashPageView: View {
    let model: StashPageModel
    @Bindable var draft: StashImportDraft
    let appearance: HistoryPageAppearance
    /// The window the page shows in: where a delete's Undo toast shows.
    let window: () -> NSWindow?

    private var colors: HistoryPageColors { appearance.colors }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            HairlineDivider(color: colors.separator)
            let shown = model.groups(matching: draft.query)
            if shown.isEmpty {
                Text(model.groups.isEmpty ? StashStrings.empty : StashStrings.noMatches)
                    .font(Font(Typography.body)).foregroundStyle(colors.tertiary).multilineTextAlignment(.center)
                    .padding(Metrics.panelInset * 3).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list(shown)
            }
        }
        .disabled(model.isBusy)
        .background(colors.background)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Metrics.panelInset * 1.5) {
            HStack(alignment: .firstTextBaseline, spacing: Metrics.panelInset * 1.5) {
                Text(StashStrings.title).font(Font(Typography.title)).foregroundStyle(colors.primary).lineLimit(1)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                if !draft.isOpen {
                    Button(StashStrings.importFromOneTab) { draft.open() }
                        .buttonStyle(.borderless).fixedSize().foregroundStyle(colors.secondary)
                }
            }
            if !model.groups.isEmpty {
                ThemedField(text: $draft.query, placeholder: StashStrings.searchPlaceholder, font: Typography.subtitle,
                            onCancel: { draft.query = "" })
            }
            if draft.isOpen { importBox }
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
            TextEditor(text: $draft.text)
                .font(Font(Typography.body)).foregroundStyle(colors.primary)
                .scrollContentBackground(.hidden).frame(minHeight: 72, maxHeight: 160)
                .padding(Metrics.panelInset / 2)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(colors.separator))
            HStack(spacing: Metrics.panelInset * 1.5) {
                Spacer(minLength: 0)
                Button(StashStrings.cancel) { draft.close() }.buttonStyle(.borderless).foregroundStyle(colors.secondary)
                Button(StashStrings.importAction) { Task { await model.importPasted(draft) } }
                    .buttonStyle(.borderless).foregroundStyle(colors.primary)
                    .disabled(draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func list(_ groups: [StashedGroup]) -> some View {
        List {
            ForEach(groups) { group in
                Section {
                    ForEach(group.tabs) { tab in
                        row(tab, in: group)
                    }
                } header: {
                    // Restore All and Delete Group take the whole group, not only the pages a search shows.
                    groupHeader(model.groups.first { $0.id == group.id } ?? group)
                }
            }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, Self.rowHeight)
        .scrollContentBackground(.hidden)
        .thinScrollers()
    }

    /// A page row: one compact line (polish bar: 26-28 px rows). No shared list-row metric exists.
    private static let rowHeight: CGFloat = 28
    private static let rowInsets = EdgeInsets(top: 0, leading: Metrics.panelInset, bottom: 0, trailing: Metrics.panelInset)

    /// A row: a button that restores its page or workspace (keyboard and VoiceOver reach it), then
    /// its ×. Globe, title, host, then the time; the full URL is the tooltip. A whole workspace
    /// shows its name and its first tabs, which are the tooltip.
    private func row(_ tab: StashedGroup.Tab, in group: StashedGroup) -> some View {
        HStack(spacing: Metrics.panelInset) {
            Button { Task { await model.restore(group, tab: tab) } } label: {
                HStack(spacing: Metrics.panelInset * 1.5) {
                    Icon(tab.isWorkspace ? .workspace : .browser, size: Metrics.iconSize)
                        .frame(width: Metrics.iconSize, height: Metrics.iconSize).foregroundStyle(colors.secondary)
                    Text(tab.displayTitle).font(Font(Typography.body)).foregroundStyle(colors.primary)
                        .lineLimit(1).truncationMode(.tail)
                    if tab.isWorkspace, !tab.workspaceTabs.isEmpty {
                        Text(tab.workspaceTabs.formatted(.list(type: .and, width: .narrow)))
                            .font(Font(Typography.caption)).foregroundStyle(colors.tertiary).lineLimit(1).layoutPriority(-1)
                    } else if let host = URL(string: tab.url)?.host(), !host.isEmpty {
                        Text(host).font(Font(Typography.caption)).foregroundStyle(colors.tertiary).lineLimit(1).layoutPriority(-1)
                    }
                    Spacer(minLength: Metrics.panelInset)
                    Text(group.createdAt.formatted(date: .omitted, time: .shortened))
                        .font(Font(Typography.caption)).foregroundStyle(colors.tertiary).monospacedDigit().fixedSize()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .themedHelp(tab.isWorkspace ? tab.workspaceTabs.joined(separator: "\n") : tab.url)
            .accessibilityHint(StashStrings.restore)
            Button { Task { await model.delete(group, tab: tab, undoIn: window()) } } label: {
                Icon(.actionClose, size: Metrics.iconSize).foregroundStyle(colors.tertiary)
            }
            .buttonStyle(.plain).themedHelp(StashStrings.delete).accessibilityLabel(StashStrings.delete)
        }
        .frame(height: Self.rowHeight)
        .contextMenu {
            Button(StashStrings.restore) { Task { await model.restore(group, tab: tab) } }
            Divider()
            Button(StashStrings.delete, role: .destructive) { Task { await model.delete(group, tab: tab, undoIn: window()) } }
        }
        .listRowInsets(Self.rowInsets)
        .listRowBackground(Color.clear)
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
            Button(StashStrings.deleteGroup) { Task { await model.delete(group, undoIn: window()) } }
                .buttonStyle(.borderless).foregroundStyle(colors.danger).fixedSize()
        }
        .padding(.vertical, 2)
        .listRowInsets(Self.rowInsets)
        .contextMenu {
            Button(StashStrings.restoreAll) { Task { await model.restore(group) } }
            Button(StashStrings.restoreInNewWorkspace) { Task { await model.restoreInNewWorkspace(group) } }
            Divider()
            Button(StashStrings.deleteGroup, role: .destructive) { Task { await model.delete(group, undoIn: window()) } }
        }
    }
}
