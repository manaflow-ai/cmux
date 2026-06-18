import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

struct TerminalTabOverviewView: View {
    let workspaceName: String
    let items: [TerminalTabOverviewItem]
    let canCloseTabs: Bool
    let onSelect: (MobileTerminalPreview.ID) -> Void
    let onClose: (MobileTerminalPreview.ID) -> Void
    let onNewTerminal: () -> Void
    let onDone: () -> Void

    private static let columns = [
        GridItem(.adaptive(minimum: 158, maximum: 230), spacing: 18, alignment: .top),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: Self.columns, alignment: .center, spacing: 22) {
                    ForEach(items) { item in
                        TerminalTabOverviewCard(
                            item: item,
                            canClose: canCloseTabs && items.count > 1,
                            onSelect: { onSelect(item.id) },
                            onClose: { onClose(item.id) }
                        )
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 88)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(L10n.string("mobile.terminal.overview.title", defaultValue: "All Tabs"))
            .navigationBarTitleDisplayMode(.large)
            .safeAreaInset(edge: .bottom) {
                bottomBar
            }
        }
        .accessibilityIdentifier("MobileTerminalOverview")
    }

    private var bottomBar: some View {
        HStack {
            Button(action: onNewTerminal) {
                Image(systemName: "plus")
                    .font(.title3.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(L10n.string("mobile.terminal.new", defaultValue: "New Terminal"))
            .accessibilityIdentifier("MobileTerminalOverviewNewTerminal")

            Spacer()

            VStack(spacing: 2) {
                Text(tabCountText)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText())
                Text(workspaceName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: 180)
            .accessibilityElement(children: .combine)

            Spacer()

            Button(L10n.string("mobile.common.done", defaultValue: "Done"), action: onDone)
                .font(.headline)
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityIdentifier("MobileTerminalOverviewDone")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.regularMaterial)
    }

    private var tabCountText: String {
        if items.count == 1 {
            return String.localizedStringWithFormat(
                L10n.string("mobile.terminal.overview.tabCount.one", defaultValue: "%d Tab"),
                items.count
            )
        }
        return String.localizedStringWithFormat(
            L10n.string("mobile.terminal.overview.tabCount.other", defaultValue: "%d Tabs"),
            items.count
        )
    }
}
