import CmuxMobileShell
import SwiftUI

/// In-place staged-pane tab list rendered over the still-streaming terminal.
struct PaneRackUnfoldView: View {
    let pane: PaneRackPaneSnapshot
    let tails: [String: PaneTail]
    let canClose: Bool
    let chromeForeground: Color
    let background: Color
    let selectTab: (PaneRackTabSnapshot) -> Void
    let requestClose: (PaneRackTabSnapshot) -> Void
    let createTab: () -> Void

    @State private var rowsVisible = false

    var body: some View {
        GeometryReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(pane.tabs.enumerated()), id: \.element.id) { index, tab in
                        PaneRackTabRow(
                            tab: tab,
                            tail: tails[tab.id.rawValue],
                            isSelected: tab.id == pane.selectedTab?.id,
                            canClose: canClose,
                            chromeForeground: chromeForeground,
                            background: background,
                            select: { selectTab(tab) },
                            close: { requestClose(tab) }
                        )
                        .opacity(rowsVisible ? 1 : 0)
                        .offset(y: rowsVisible ? 0 : -6)
                        .animation(
                            .spring(response: 0.32, dampingFraction: 0.86)
                                .delay(Double(index) * 0.02),
                            value: rowsVisible
                        )
                    }
                    PaneRackNewTerminalRow(
                        chromeForeground: chromeForeground,
                        background: background,
                        create: createTab
                    )
                    .opacity(rowsVisible ? 1 : 0)
                    .offset(y: rowsVisible ? 0 : -6)
                    .animation(
                        .spring(response: 0.32, dampingFraction: 0.86)
                            .delay(Double(pane.tabs.count) * 0.02),
                        value: rowsVisible
                    )
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(CGFloat(pane.tabs.count * 44 + 40), proxy.size.height))
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .onAppear { rowsVisible = true }
        .onDisappear { rowsVisible = false }
    }
}
