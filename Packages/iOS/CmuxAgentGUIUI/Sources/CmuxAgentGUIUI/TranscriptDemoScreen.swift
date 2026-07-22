#if DEBUG && os(iOS)
import CMUXMobileCore
import CmuxAgentChatUI
import CmuxAgentGUIProjection
import CmuxMobileSupport
public import SwiftUI

/// DEBUG-only replay-driven transcript demo using the production native list.
public struct TranscriptDemoScreen: View {
    @State private var model = TranscriptDemoModel()
    @State private var density: TranscriptDensity
    @State private var activityDetails: TranscriptActivityDetails?
    @State private var followState: ConversationFollowState<String> = .followingTail
    @State private var scrollCommand: ConversationScrollCommand?
    @State private var scrollGeneration = 0
    @State private var markdownRenderer = ChatMarkdownRenderer()
    @State private var contentCache = ChatContentCache()

    public init() {
        let rawDensity = UITestEnvironmentConfig(
            environment: ProcessInfo.processInfo.environment
        ).transcriptDensity
        _density = State(initialValue: rawDensity.flatMap(TranscriptDensity.init(rawValue:)) ?? .comfortable)
    }

    public var body: some View {
        let theme = AgentGUITheme(terminalTheme: .monokai)
        let appearance = AgentTranscriptAppearance(theme: theme, density: density)
        let rows = AgentTranscriptRenderAdapter().rows(
            from: TranscriptProjector().project(model.input).rows
        )
        ConversationKeyboardContainer {
            NativeConversationTranscript(
                rows: rows,
                hasMoreBefore: model.input.hasMoreBefore,
                followState: $followState,
                command: scrollCommand,
                isActive: activityDetails == nil
            ) { row in
                AgentTranscriptRowView(
                    row: row,
                    theme: theme,
                    density: density,
                    onOpenAsk: { _ in },
                    onOpenActivity: { activityDetails = $0 },
                    onOpenFailedTicket: { _ in },
                    onRetrySync: {},
                    onShowTerminal: {},
                    onShowCodeBlock: { _, _ in }
                )
            }
        } composer: {
            TranscriptDemoComposerView(
                model: model,
                density: $density,
                jumpToBottom: jumpToBottom
            )
        }
        .environment(\.chatTheme, appearance.chatTheme)
        .environment(\.chatMarkdownRenderer, markdownRenderer)
        .environment(\.chatContentCache, contentCache)
        .environment(\.colorScheme, appearance.colorScheme)
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .background(Color(theme.background).ignoresSafeArea())
        .navigationTitle(AgentGUIL10n.string("agent.demo.title", defaultValue: "Transcript Demo"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $activityDetails) { details in
            TranscriptActivityTimelineView(details: details, terminalTheme: .monokai)
                .presentationDetents([.medium, .large])
        }
        .onDisappear { model.tearDown() }
    }

    private func jumpToBottom() {
        followState = .followingTail
        scrollGeneration += 1
        scrollCommand = ConversationScrollCommand(generation: scrollGeneration, target: .tail)
    }
}
#endif
