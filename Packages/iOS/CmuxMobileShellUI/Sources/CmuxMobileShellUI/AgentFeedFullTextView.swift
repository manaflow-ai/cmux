#if os(iOS)
import CmuxAgentChatUI
import CmuxMobileShellModel
import SwiftUI

/// Reading state is local to the sheet and never retained by timeline rows.
struct AgentFeedFullTextView: View {
    let item: MobileAgentFeedItem
    let load: @MainActor (MobileAgentFeedItem) async throws -> String
    @Environment(\.dismiss) private var dismiss
    @State private var text: String?
    @State private var failed = false
    @State private var attempt = 0

    var body: some View {
        NavigationStack {
            Group {
                if let text {
                    ChatArtifactEmbeddedMarkdown(markdown: text)
                        .accessibilityIdentifier("MobileAgentFeedFullTextBody")
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            if failed {
                                Text(String(localized: "mobile.agentFeed.fullText.unavailable",
                                            defaultValue: "Couldn’t load the full text from this Mac. Reconnect and try again.",
                                            bundle: .module))
                                Button(String(localized: "mobile.agentFeed.fullText.retry",
                                              defaultValue: "Try again", bundle: .module)) {
                                    attempt += 1
                                }
                            } else {
                                ProgressView(String(localized: "mobile.agentFeed.fullText.loading",
                                                    defaultValue: "Loading full text…", bundle: .module))
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle(String(localized: "mobile.agentFeed.fullText.title",
                                    defaultValue: "Full text", bundle: .module))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "mobile.agentFeed.fullText.close",
                                  defaultValue: "Close", bundle: .module)) {
                        dismiss()
                    }
                    .accessibilityIdentifier("MobileAgentFeedFullTextClose")
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .task(id: attempt) {
            failed = false
            do {
                let loaded = try await load(item)
                try Task.checkCancellation()
                text = loaded
            } catch {
                guard !Task.isCancelled else { return }
                failed = true
            }
        }
    }
}
#endif
