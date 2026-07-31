import SwiftUI

/// Search, time-range, sorting, and reload controls for History.
struct VaultHistoryControls: View {
    @Bindable var model: VaultHistoryTimelineModel
    let isReloadDisabled: Bool
    let onReload: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                timeRangeMenu
                Spacer(minLength: 4)
                sortMenu
                reloadButton
            }
            .rightSidebarChromeBar()

            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .cmuxFont(size: 10)
                    .foregroundColor(.secondary)
                TextField(
                    String(localized: "vaultHistory.search.placeholder", defaultValue: "Search history"),
                    text: $model.searchText
                )
                .textFieldStyle(.plain)
                .cmuxFont(size: 11)
                .accessibilityIdentifier("VaultHistorySearchField")
                if !model.searchText.isEmpty {
                    Button {
                        model.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .cmuxFont(size: 10)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(
                        localized: "vaultHistory.search.clear.tooltip",
                        defaultValue: "Clear history search"
                    ))
                    .help(String(
                        localized: "vaultHistory.search.clear.tooltip",
                        defaultValue: "Clear history search"
                    ))
                }
            }
            .padding(.horizontal, 10)
            .frame(height: RightSidebarChromeMetrics.secondaryBarHeight)
        }
        .rightSidebarChromeBottomBorder()
    }

    private var timeRangeMenu: some View {
        Menu {
            ForEach(VaultHistoryQuery.TimeRange.allCases) { range in
                Button {
                    model.timeRange = range
                } label: {
                    if model.timeRange == range {
                        Label(range.label, systemImage: "checkmark")
                    } else {
                        Text(range.label)
                    }
                }
            }
        } label: {
            Label(model.timeRange.label, systemImage: model.timeRange.symbolName)
                .cmuxFont(
                    size: RightSidebarChromeControlStyle.labelSize,
                    weight: RightSidebarChromeControlStyle.labelWeight
                )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(String(localized: "vaultHistory.rangePicker.tooltip", defaultValue: "Filter history by time"))
        .accessibilityIdentifier("VaultHistoryTimeRangePicker")
        .titlebarInteractiveControl()
    }

    private var sortMenu: some View {
        Menu {
            ForEach(VaultHistoryQuery.SortOrder.allCases) { order in
                Button {
                    model.sortOrder = order
                } label: {
                    if model.sortOrder == order {
                        Label(order.label, systemImage: "checkmark")
                    } else {
                        Text(order.label)
                    }
                }
            }
        } label: {
            Label(model.sortOrder.label, systemImage: model.sortOrder.symbolName)
                .labelStyle(.iconOnly)
                .cmuxFont(
                    size: RightSidebarChromeControlStyle.secondaryIconSize,
                    weight: RightSidebarChromeControlStyle.iconWeight
                )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(String(localized: "vaultHistory.sortPicker.tooltip", defaultValue: "Sort history"))
        .accessibilityIdentifier("VaultHistorySortPicker")
        .titlebarInteractiveControl()
    }

    private var reloadButton: some View {
        Button {
            onReload()
        } label: {
            Image(systemName: "arrow.clockwise")
                .cmuxFont(size: 10, weight: .medium)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(String(localized: "vaultHistory.reload.tooltip", defaultValue: "Reload History"))
        .help(String(localized: "vaultHistory.reload.tooltip", defaultValue: "Reload History"))
        .disabled(isReloadDisabled)
        .titlebarInteractiveControl()
    }
}
