import SwiftUI

/// Chrome row shown for every Vault grouping: session search and view density.
/// Mounted directly by
/// `SessionIndexView` above the table boundary, mirroring the existing control
/// bar (safe to observe the store here — never inside table rows).
struct VaultAllSessionsBar: View {
    @Binding var searchText: String
    /// Shared row-density preference. Default view shows repository/branch
    /// details; compact view hides that second line in every Vault grouping.
    @Binding var isCompactView: Bool
    /// Enter — peek the top search result.
    let onPeekTopResult: () -> Void
    /// Cmd+Enter — resume the top search result.
    let onResumeTopResult: () -> Void

    @FocusState private var searchFieldFocused: Bool
    @Environment(\.cmuxGlobalFontMagnificationPercent) private var globalFontPercent

    private var searchFieldHeight: CGFloat {
        _ = globalFontPercent
        // A native NSSearchField sits at roughly 22 points on macOS. Keep
        // that comfortable baseline while allowing the app-wide text scale
        // to grow the control instead of clipping its editor.
        return max(22, RightSidebarChromeMetrics.controlHeight + 2)
    }

    private var searchBarHeight: CGFloat {
        max(RightSidebarChromeMetrics.secondaryBarHeight, searchFieldHeight + 6)
    }

    var body: some View {
        HStack(spacing: 0) {
            searchField
            overflowMenu
        }
        // Keep the same 28-point rhythm and 4/6-point outer insets as the
        // mode bar, but let this toolbar flow into the session list without a
        // second separator line. The field itself is two points taller than
        // the compact icon controls, so use three-point vertical insets here.
        .padding(.leading, 4)
        .padding(.trailing, 0)
        .padding(.vertical, 3)
        .frame(height: searchBarHeight)
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .cmuxFont(size: 12, weight: .regular)
                .foregroundColor(.secondary)
            TextField(
                String(localized: "sessionIndex.allSessions.searchPlaceholder",
                       defaultValue: "Search sessions…"),
                text: $searchText
            )
            .textFieldStyle(.plain)
            .cmuxFont(size: 13)
            .focused($searchFieldFocused)
            .onSubmit { onPeekTopResult() }
            .onKeyPress(.return, phases: .down) { press in
                guard press.modifiers.contains(.command) else { return .ignored }
                onResumeTopResult()
                return .handled
            }
            .onKeyPress(.escape) {
                guard !searchText.isEmpty else { return .ignored }
                searchText = ""
                return .handled
            }
            .accessibilityIdentifier("VaultAllSessionsSearchField")
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .cmuxFont(size: 12)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(String(localized: "sessionIndex.allSessions.clearSearch",
                                                defaultValue: "Clear search")))
            }
        }
        // A plain editor inside one low-contrast, borderless control fill
        // keeps the behavior of a normal macOS search field without adding a
        // second outline to the chrome.
        .padding(.horizontal, 9)
        .frame(height: searchFieldHeight)
        .background(
            RoundedRectangle(
                cornerRadius: 7,
                style: .continuous
            )
                .fill(Color.primary.opacity(0.06))
        )
        // The field owns the flexible width; the utility controls keep their
        // standard 20-point targets at the trailing edge.
        .frame(maxWidth: .infinity, alignment: .leading)
        .layoutPriority(1)
        .titlebarInteractiveControl()
    }

    private var overflowMenu: some View {
        Menu {
            Picker(
                String(localized: "sessionIndex.view.title", defaultValue: "Session view"),
                selection: $isCompactView
            ) {
                Text(String(localized: "sessionIndex.view.default", defaultValue: "Default view"))
                    .tag(false)
                Text(String(localized: "sessionIndex.view.compact", defaultValue: "Compact view"))
                    .tag(true)
            }
            .pickerStyle(.inline)
        } label: {
            Text("⋮")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(Color.secondary.opacity(0.72))
                .frame(width: 24, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.10))
                )
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .contentShape(Rectangle())
        .help(String(localized: "sessionIndex.view.tooltip", defaultValue: "Choose session view"))
        .accessibilityLabel(Text(String(localized: "sessionIndex.view.title", defaultValue: "Session view")))
        .accessibilityHint(Text(String(localized: "sessionIndex.view.tooltip", defaultValue: "Choose session view")))
        .accessibilityValue(viewSelectionLabel)
        .accessibilityIdentifier("VaultSessionOptionsMenu")
        .frame(width: 24, height: 28)
        .layoutPriority(2)
        .titlebarInteractiveControl()
    }

    private var viewSelectionLabel: String {
        if isCompactView {
            return String(localized: "sessionIndex.view.compact", defaultValue: "Compact view")
        }
        return String(localized: "sessionIndex.view.default", defaultValue: "Default view")
    }

}
