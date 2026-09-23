#if os(iOS) && DEBUG
import CmuxMobileShellModel
import SwiftUI

/// Isolated fixture that exercises the production row and reading sheet.
public struct AgentFeedFullTextPreviewView: View {
    @State private var attempts = 0
    private let failsOnce: Bool
    private let item: MobileAgentFeedItem
    private let fullText: String

    public init(failsOnce: Bool = false) {
        self.failsOnce = failsOnce
        let text = (1...24).map { number in
            "Paragraph \(number). This response keeps its complete explanation, line breaks, and Unicode 👩🏽‍💻."
        }.joined(separator: "\n\n") + "\n\nFINAL PARAGRAPH: The complete response ends here."
        fullText = text
        let now = Date()
        item = MobileAgentFeedItem(
            macDeviceID: "preview-mac", macDisplayName: "Preview Mac",
            itemID: "full-text-preview", workstreamID: "codex-preview", source: "codex",
            kind: .stop, status: .telemetry, createdAt: now, updatedAt: now,
            stopReason: String(text.prefix(200)) + "…", connectionStatus: .connected
        )
    }

    public var body: some View {
        NavigationStack {
            AgentFeedView(
                items: [item], status: .ready, pendingReplyRequestIDs: [],
                pendingTerminalReplyItemIDs: [], refreshesOnAppear: false,
                actions: AgentFeedActions(loadFullText: { _ in
                    attempts += 1
                    if failsOnce && attempts == 1 { throw URLError(.notConnectedToInternet) }
                    return fullText
                })
            )
        }
    }
}
#endif
