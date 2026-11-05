#if os(iOS)
import CmuxMobileDesign
import CmuxTabsKit
import SwiftUI

/// The address bar's editing page: Open Address in New Tab (the Mac omnibar's row) over
/// TabsKit's own suggestions (Switch to Tab, Search), with matching tabs of other workspaces between. The row opens what is typed in a new
/// browser tab beside the edited one on the Mac and goes to it; the edited tab keeps its page.
public struct WorkspaceAddressSuggestions: View {
    let editing: TabsKitAddressEditing
    let source: WorkspaceTabsSource
    @Environment(\.tabsKitTheme) private var theme

    public var body: some View {
        let others = otherWorkspaceTabs
        let opensInNewTab = source.canOpenAddressInNewTab(editing) && editing.tab != nil
        if opensInNewTab || !others.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                if opensInNewTab, let id = editing.tab?.id { newTabRow(id) }
                if !others.isEmpty { otherWorkspacesSection(others) }
                TabsKitAddressSuggestions(below(editing))
            }
            .padding(.top, editing.safeTop + 8)
            .background(theme.colors.pageBackground)
        } else {
            TabsKitAddressSuggestions(editing)
        }
    }

    /// Search Tabs across workspaces (the Mac's `tab.search`): tabs of other workspaces whose
    /// name or address matches what is typed, which TabsKit's Switch to Tab (this workspace's
    /// tabs) cannot list. Nothing while the field holds the tab's own address.
    private var otherWorkspaceTabs: [PaletteCommand] {
        let query = editing.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty { return [] }
        if case .url(_, let shown, _)? = editing.tab?.address, shown == editing.query { return [] }
        return source.paletteTabs(matching: query, otherWorkspacesOnly: true, limit: 4)
    }

    private func otherWorkspacesSection(_ hits: [PaletteCommand]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header("Other workspaces")
            ForEach(hits) { hit in
                Button {
                    // The field closes on the edited tab (its page unchanged), then the other workspace shows.
                    if let id = editing.tab?.id { editing.switchToTab(id) }
                    hit.run()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: hit.systemImage).font(.system(size: 17))
                            .frame(width: 24, height: 24)
                            .foregroundStyle(theme.colors.secondaryLabel)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(hit.title).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                                .foregroundStyle(theme.colors.label)
                            Text(hit.subtitle ?? "").font(.system(size: 13)).lineLimit(1)
                                .foregroundStyle(theme.colors.secondaryLabel)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 57)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .accessibilityIdentifier("address.otherWorkspace.\(hit.id)")
            }
        }
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(theme.colors.secondaryLabel)
            .padding(.horizontal, 32)
            .frame(height: 40, alignment: .bottomLeading)
            .padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }

    private func newTabRow(_ id: TabsKitTab.ID) -> some View {
        let text = editing.query.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: 0) {
            Text("New Tab")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.colors.secondaryLabel)
                .padding(.horizontal, 32)
                .frame(height: 40, alignment: .bottomLeading)
                .padding(.bottom, 4)
                .accessibilityAddTraits(.isHeader)
            Button {
                Task { @MainActor in
                    if let opened = await source.openAddressInNewTab(text, besides: id) { editing.switchToTab(opened) }
                }
            } label: {
                HStack(spacing: 0) {
                    Image(systemName: "plus.square.on.square").font(.system(size: 17))
                        .foregroundStyle(theme.colors.secondaryLabel)
                        .frame(width: 30)
                        .padding(.leading, 3)
                    Text(text).font(.system(size: 17)).lineLimit(1)
                        .foregroundStyle(theme.colors.label)
                        .padding(.leading, 15)
                    Spacer(minLength: 0)
                    if source.pendingTabTitle == WorkspaceTabsSource.openAddressTitle {
                        ProgressView().padding(.trailing, 4)
                    }
                }
                .frame(height: 52)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .disabled(source.pendingTabTitle != nil)
            .accessibilityLabel(Text("\(WorkspaceTabsSource.openAddressTitle): \(text)"))
            .accessibilityIdentifier("address.openInNewTab")
        }
    }

    /// The kit's suggestions start right under the row, not under the status bar.
    private func below(_ editing: TabsKitAddressEditing) -> TabsKitAddressEditing {
        var editing = editing
        editing.safeTop = 0
        return editing
    }
}
#endif
