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
    @State private var didStartAutomation = false

    public init() {
        let rawDensity = UITestEnvironmentConfig(
            environment: ProcessInfo.processInfo.environment
        ).transcriptDensity
        _density = State(initialValue: rawDensity.flatMap(TranscriptDensity.init(rawValue:)) ?? .compact)
    }

    public var body: some View {
        let theme = AgentGUITheme(terminalTheme: .monokai)
        let appearance = AgentTranscriptAppearance(theme: theme, density: density)
        let title = AgentGUIL10n.string("agent.demo.title", defaultValue: "Transcript Demo")
        ConversationKeyboardContainer {
            NativeConversationTranscript(
                rows: model.renderedRows,
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
                    onOpenActivity: { rowID in
                        activityDetails = AgentTranscriptRowSelectionResolver.activity(
                            rowID: rowID,
                            rows: model.renderedRows
                        )
                    },
                    onOpenFailedTicket: { _ in },
                    onRetrySync: {},
                    onShowTerminal: {},
                    onOpenArtifact: { _ in },
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
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(title)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(Color(theme.foreground))
                    .accessibilityAddTraits(.isHeader)
            }
        }
        .toolbarBackground(Color(theme.background), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(appearance.colorScheme, for: .navigationBar)
        .sheet(item: $activityDetails) { details in
            TranscriptActivityTimelineView(details: details, terminalTheme: .monokai)
                .presentationDetents([.medium, .large])
        }
        .task {
            await runAutomationIfRequested()
        }
        .onDisappear { model.tearDown() }
    }

    private func jumpToBottom() {
        followState = .followingTail
        scrollGeneration += 1
        scrollCommand = ConversationScrollCommand(generation: scrollGeneration, target: .tail)
    }

    private func runAutomationIfRequested() async {
        guard !didStartAutomation else {
            return
        }
        let env = ProcessInfo.processInfo.environment
        let enabled = env["CMUX_UITEST_TRANSCRIPT_DEMO_SEED"] == "full"
            || env["CMUX_UITEST_TRANSCRIPT_DEMO_AUTOPLAY"] == "1"
            || env["CMUX_UITEST_TRANSCRIPT_DEMO_STREAMING"] == "1"
            || env["CMUX_UITEST_TRANSCRIPT_DEMO_BURST"] == "1"
            || env["CMUX_UITEST_TRANSCRIPT_DEMO_TALL"] == "1"
            || env["CMUX_UITEST_TRANSCRIPT_DEMO_TOGGLE_DENSITY"] == "1"
        guard enabled else {
            return
        }
        didStartAutomation = true

        if env["CMUX_UITEST_TRANSCRIPT_DEMO_SEED"] == "full" {
            model.seedReplayForAutomation()
        }

        let startDelayMs = env["CMUX_UITEST_TRANSCRIPT_DEMO_START_DELAY_MS"].flatMap(Int.init) ?? 0
        if startDelayMs > 0 {
            try? await Task.sleep(for: .milliseconds(max(1, startDelayMs)))
        }

        if env["CMUX_UITEST_TRANSCRIPT_DEMO_AUTOPLAY"] == "1" {
            let delayMs = env["CMUX_UITEST_TRANSCRIPT_DEMO_DELAY_MS"].flatMap(Int.init) ?? 180
            await model.playReplayForAutomation(delayMs: delayMs)
        }

        if env["CMUX_UITEST_TRANSCRIPT_DEMO_STREAMING"] == "1" {
            try? await Task.sleep(for: .milliseconds(450))
            model.injectStreamingTick()
        }

        if env["CMUX_UITEST_TRANSCRIPT_DEMO_BURST"] == "1" {
            try? await Task.sleep(for: .milliseconds(450))
            model.appendBurstRows()
        }

        if env["CMUX_UITEST_TRANSCRIPT_DEMO_TALL"] == "1" {
            try? await Task.sleep(for: .milliseconds(450))
            model.setTallFixtureEnabled(true)
        }

        if env["CMUX_UITEST_TRANSCRIPT_DEMO_TOGGLE_DENSITY"] == "1" {
            let delayMs = env["CMUX_UITEST_TRANSCRIPT_DEMO_TOGGLE_DELAY_MS"].flatMap(Int.init) ?? 700
            try? await Task.sleep(for: .milliseconds(max(1, delayMs)))
            density = density == .comfortable ? .compact : .comfortable
        }
    }
}
#endif
