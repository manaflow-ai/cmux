import CMUXAgentLaunch
import SwiftUI
import Testing

@testable import CmuxFeedUI

/// Smoke coverage for the presentational leaf views relocated out of the Feed
/// god file: every public initializer must stay reachable from outside the
/// package and forward its arguments unchanged so the app target keeps
/// constructing them exactly as before the move.
@Suite struct FeedLeafViewConstructionTests {
    @Test func markdownInlineTextForwardsArguments() {
        let view = FeedMarkdownInlineText(
            text: "**hi**",
            fontSize: 11,
            weight: .semibold,
            foregroundColor: .secondary
        )
        #expect(view.text == "**hi**")
        #expect(view.fontSize == 11)
        #expect(view.weight == .semibold)
    }

    @Test func labeledTextRowForwardsArguments() {
        let view = FeedLabeledTextRow(
            label: "You:",
            text: "hello",
            labelColor: .secondary,
            textColor: .primary,
            rendersMarkdown: true
        )
        #expect(view.label == "You:")
        #expect(view.text == "hello")
        #expect(view.rendersMarkdown)
    }

    @Test func contextBlockForwardsArguments() {
        let context = WorkstreamContext(lastUserMessage: "hi", assistantPreamble: "ok", planSummary: "do x")
        let view = FeedContextBlock(context: context, source: .claude)
        #expect(view.context.lastUserMessage == "hi")
        #expect(view.source == .claude)
    }

    @Test func planBodyForwardsArguments() {
        let view = PlanBodyView(plan: "1. first\n- bullet", rendersMarkdown: true)
        #expect(view.plan == "1. first\n- bullet")
        #expect(view.rendersMarkdown)
    }

    @Test func exitPlanAllowedPromptsForwardsArguments() {
        let view = ExitPlanAllowedPromptsView(
            prompts: [WorkstreamAllowedPrompt(tool: "Bash", prompt: "ls")]
        )
        #expect(view.prompts.count == 1)
        #expect(view.prompts.first?.tool == "Bash")
    }

    @Test func exitPlanPlanFileForwardsArguments() {
        let view = ExitPlanPlanFileView(path: "/tmp/plan.md")
        #expect(view.path == "/tmp/plan.md")
    }
}
