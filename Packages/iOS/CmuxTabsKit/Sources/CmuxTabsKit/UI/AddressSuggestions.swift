#if os(iOS)
import SwiftUI

/// The default editing background: open tabs matching the query ("Switch
/// to Tab") and a Search row, on the page background.
public struct TabsKitAddressSuggestions: View {
    var editing: TabsKitAddressEditing
    @Environment(\.tabsKitTheme) private var theme

    public init(_ editing: TabsKitAddressEditing) {
        self.editing = editing
    }

    private var query: String { editing.query.trimmingCharacters(in: .whitespaces) }

    private var matches: [TabsKitTab] {
        let q = query.lowercased()
        let others = editing.tabs.filter { $0.id != editing.tab?.id }
        if q.isEmpty || isUnchanged { return others }
        return others.filter { $0.title.lowercased().contains(q) || $0.subtitle.lowercased().contains(q) }
    }

    /// The field still holds the tab's own address.
    private var isUnchanged: Bool {
        if case .url(_, let text, _)? = editing.tab?.address { return text == editing.query }
        return false
    }

    public var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                if !matches.isEmpty {
                    header(query.isEmpty || isUnchanged ? "Open Tabs" : "Switch to Tab")
                    ForEach(matches) { tab in
                        Button { editing.switchToTab(tab.id) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: tab.systemImage).font(.system(size: 17))
                                    .frame(width: 24, height: 24)
                                    .foregroundStyle(theme.colors.secondaryLabel)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(tab.title)
                                        .font(.system(size: 17, weight: .semibold)).lineLimit(1)
                                        .foregroundStyle(theme.colors.label)
                                    Text(tab.subtitle.isEmpty ? "Opened Tab" : "\(tab.subtitle) · Opened Tab")
                                        .font(.system(size: 13)).lineLimit(1)
                                        .foregroundStyle(theme.colors.secondaryLabel)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 16)
                            .frame(height: 57)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
                if !query.isEmpty, !isUnchanged {
                    header("Search")
                    row(symbol: "magnifyingglass", text: query) { editing.go(query) }
                }
            }
            .padding(.top, editing.safeTop + 8)
            .padding(.bottom, 400)
            .padding(.horizontal, 16)
        }
        .scrollDismissesKeyboard(.never)
        .background(theme.colors.pageBackground)
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(theme.colors.secondaryLabel)
            .padding(.horizontal, 16)
            .frame(height: 40, alignment: .bottomLeading)
            .padding(.bottom, 4)
    }

    private func row(symbol: String, text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 0) {
                Image(systemName: symbol).font(.system(size: 17))
                    .foregroundStyle(theme.colors.secondaryLabel)
                    .frame(width: 30)
                    .padding(.leading, 3)
                Text(text).font(.system(size: 17)).lineLimit(1)
                    .foregroundStyle(theme.colors.label)
                    .padding(.leading, 15)
                Spacer(minLength: 0)
            }
            .frame(height: 52)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}
#endif
