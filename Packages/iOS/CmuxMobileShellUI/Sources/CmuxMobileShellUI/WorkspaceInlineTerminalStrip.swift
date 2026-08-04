import CMUXMobileCore
import CmuxMobileShellModel
import SwiftUI

/// Horizontal terminal strip inserted above the active workspace surface.
struct WorkspaceInlineTerminalStrip: View {
    let rows: [TerminalPickerMenuRow]
    let selectedID: MobileTerminalPreview.ID?
    let terminalTheme: TerminalTheme
    let select: (MobileTerminalPreview.ID) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 8) {
                    ForEach(rows) { row in
                        WorkspaceInlineTerminalTab(
                            row: row,
                            isSelected: row.id == selectedID,
                            terminalTheme: terminalTheme,
                            select: select
                        )
                        .id(row.id)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .scrollIndicators(.hidden)
            .onAppear { scrollToSelection(with: proxy) }
            .onChange(of: selectedID) { _, _ in scrollToSelection(with: proxy) }
        }
        .background(terminalTheme.terminalBackgroundColor.opacity(0.97))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(terminalTheme.terminalChromeForegroundColor.opacity(0.12))
                .frame(height: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("MobileInlineTerminalStrip")
    }

    private func scrollToSelection(with proxy: ScrollViewProxy) {
        guard let selectedID else { return }
        withAnimation(.snappy(duration: 0.2)) {
            proxy.scrollTo(selectedID, anchor: .center)
        }
    }
}
