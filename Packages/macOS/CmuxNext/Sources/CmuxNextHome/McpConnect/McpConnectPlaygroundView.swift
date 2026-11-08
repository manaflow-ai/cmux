#if DEBUG
import CmuxNextDesign
import SwiftUI

/// DEBUG ONLY: the MCP Connect Card Playground's content: pickers on top, then the same card in a
/// light and a dark theme side by side. The cards are live: Connect, Cancel, the scope menu and the
/// key field step the real ``McpConnectCardFlow``; "Finish sign-in" plays the daemon's part.
struct McpConnectPlaygroundView: View {
    @Bindable var model: McpConnectPlaygroundModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Picker("Style", selection: $model.style) {
                    ForEach(McpConnectCardStyle.allCases, id: \.self) { Text("\($0.rawValue). \($0.title)").tag($0) }
                }.fixedSize()
                Picker("Server", selection: $model.fixture) {
                    ForEach(McpConnectCardFixture.allCases, id: \.self) { Text($0.title).tag($0) }
                }.fixedSize()
                Picker("Phase", selection: $model.phase) {
                    ForEach(McpConnectPlaygroundPhase.allCases, id: \.self) { Text($0.title).tag($0) }
                }.fixedSize()
                Button("Finish sign-in") { model.finishSignIn() }
                    .disabled(model.flow.phase != .signingIn && model.flow.phase != .connecting)
            }
            HStack(alignment: .top, spacing: 0) {
                column(McpConnectPlaygroundModel.light, background: McpConnectPlaygroundModel.lightTokens)
                column(McpConnectPlaygroundModel.dark, background: McpConnectPlaygroundModel.darkTokens)
            }
        }
        .padding(14)
    }

    private func column(_ colors: McpConnectCardColors, background: ThemeTokens) -> some View {
        McpConnectCardView(flow: model.flow, style: model.style, colors: colors, actions: model.actions)
            .id("\(model.style.rawValue)-\(model.fixture.rawValue)-\(model.phase.rawValue)-\(model.generation)")
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(background.contentBackground.swiftUIColor)
    }
}
#endif
