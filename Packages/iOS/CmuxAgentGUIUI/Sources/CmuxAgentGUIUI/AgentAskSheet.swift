#if os(iOS)
import CmuxAgentGUIProjection
import CmuxAgentReplica
import SwiftUI

struct AgentAskSheet: View {
    let ask: PendingAsk
    let theme: AgentGUITheme
    let canAnswer: Bool
    let isAnswering: Bool
    let errorMessage: String?
    let onAnswer: (Int) -> Void
    let onShowTerminal: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(ask.promptSummary)
                        .font(.body)
                        .textSelection(.enabled)
                    if !canAnswer {
                        Text(AgentGUIL10n.string(
                            "agent.ask.terminalRequired",
                            defaultValue: "Answer this request in Terminal."
                        ))
                            .font(.footnote)
                            .foregroundStyle(Color(theme.dimForeground))
                        Button(
                            AgentGUIL10n.string("agent.ask.showTerminal", defaultValue: "Show Terminal"),
                            action: onShowTerminal
                        )
                        .buttonStyle(.borderedProminent)
                    } else if ask.options.isEmpty {
                        Button(
                            AgentGUIL10n.string("agent.ask.showTerminal", defaultValue: "Show Terminal"),
                            action: onShowTerminal
                        )
                        .buttonStyle(.borderedProminent)
                    } else {
                        ForEach(Array(ask.options.enumerated()), id: \.offset) { index, option in
                            Button {
                                onAnswer(index)
                            } label: {
                                HStack {
                                    Text(option).frame(maxWidth: .infinity, alignment: .leading)
                                    if isAnswering { ProgressView().controlSize(.small) }
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(isAnswering)
                            .accessibilityIdentifier("AgentAskOption-\(index)")
                        }
                    }
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                .padding(24)
            }
            .background(Color(theme.background))
            .navigationTitle(ask.kind == .permission
                ? AgentGUIL10n.string("agent.ask.permission", defaultValue: "Permission needed")
                : AgentGUIL10n.string("agent.ask.question", defaultValue: "Question"))
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
#endif
