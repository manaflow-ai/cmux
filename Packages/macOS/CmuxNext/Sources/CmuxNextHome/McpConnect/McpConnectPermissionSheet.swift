import SwiftUI

/// Style 3: a big mark over "Connect X?", the access as bullets, then the server and the controls.
struct McpConnectPermissionSheet: View {
    let flow: McpConnectCardFlow
    let colors: McpConnectCardColors
    let actions: McpConnectCardActions

    var body: some View {
        let card = flow.card
        VStack(alignment: .center, spacing: 10) {
            McpConnectMark(title: card.title, size: 44, colors: colors)
            Text(McpConnectStrings.connectTitle(card.title)).font(colors.title).foregroundStyle(colors.text)
            McpConnectBadge(card: card, colors: colors)
            McpConnectReason(card: card, colors: colors).multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(bullets(card), id: \.self) { line in
                    Label(line, systemImage: "circle.fill").labelStyle(McpConnectBulletStyle(colors: colors))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            McpConnectFacts(card: card, colors: colors).frame(maxWidth: .infinity, alignment: .leading)
            McpConnectRiskLines(card: card, colors: colors).frame(maxWidth: .infinity, alignment: .leading)
            if flow.phase == .ask { McpConnectScopeMenu(flow: flow, colors: colors, actions: actions) }
            McpConnectControls(flow: flow, colors: colors, actions: actions)
        }
    }

    private func bullets(_ card: McpConnectCard) -> [String] {
        card.scopes.isEmpty ? [McpConnectAccessText(card: card).text] : card.scopes
    }
}

/// A small dot before each access line.
struct McpConnectBulletStyle: LabelStyle {
    let colors: McpConnectCardColors

    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            configuration.icon.font(colors.caption).scaleEffect(0.4).foregroundStyle(colors.tertiary)
            configuration.title.font(colors.body).foregroundStyle(colors.text)
        }
    }
}
