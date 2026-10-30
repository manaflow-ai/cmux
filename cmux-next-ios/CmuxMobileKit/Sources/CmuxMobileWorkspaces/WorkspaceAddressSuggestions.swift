#if os(iOS)
import CmuxMobileDesign
import CmuxTabsKit
import SwiftUI

/// The address bar's editing page: Open Address in New Tab (the Mac omnibar's row) over
/// TabsKit's own suggestions (Switch to Tab, Search). The row opens what is typed in a new
/// browser tab beside the edited one on the Mac and goes to it; the edited tab keeps its page.
public struct WorkspaceAddressSuggestions: View {
    let editing: TabsKitAddressEditing
    let source: WorkspaceTabsSource
    @Environment(\.tabsKitTheme) private var theme

    public var body: some View {
        if source.canOpenAddressInNewTab(editing), let id = editing.tab?.id {
            let text = editing.query.trimmingCharacters(in: .whitespacesAndNewlines)
            VStack(alignment: .leading, spacing: 0) {
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
                TabsKitAddressSuggestions(below(editing))
            }
            .padding(.top, editing.safeTop + 8)
            .background(theme.colors.pageBackground)
        } else {
            TabsKitAddressSuggestions(editing)
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
