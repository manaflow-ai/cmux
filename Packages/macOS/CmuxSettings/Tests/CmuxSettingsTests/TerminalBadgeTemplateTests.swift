import Foundation
import Testing
@testable import CmuxSettings

/// Behavior of ``TerminalBadgeTemplate/render(context:)``: iTerm2-style
/// free-form text with `{placeholder}` substitution, resilient to missing
/// values and unknown tokens.
@Suite("TerminalBadgeTemplate.render")
struct TerminalBadgeTemplateTests {
    private let fullContext = TerminalBadgeContext(
        workspace: "feature/login",
        tab: "claude",
        tabIndex: 2,
        workspaceIndex: 3
    )

    @Test func substitutesAllKnownPlaceholders() {
        let template = TerminalBadgeTemplate(
            rawValue: "{workspace} · {tab} [{tabIndex}/{workspaceIndex}]"
        )
        #expect(template.render(context: fullContext) == "feature/login · claude [2/3]")
    }

    @Test func defaultTemplateIsWorkspaceAndTab() {
        let template = TerminalBadgeTemplate(rawValue: TerminalBadgeTemplate.defaultRawValue)
        #expect(template.render(context: fullContext) == "feature/login · claude")
    }

    @Test func freeFormLiteralTextPassesThrough() {
        let template = TerminalBadgeTemplate(rawValue: "PROD — do not deploy")
        #expect(template.render(context: fullContext) == "PROD — do not deploy")
    }

    @Test func unknownPlaceholderIsLeftVerbatim() {
        // A typo or unsupported field stays visible (braces included) rather
        // than silently vanishing.
        let template = TerminalBadgeTemplate(rawValue: "{workspace} {cwd}")
        #expect(template.render(context: fullContext) == "feature/login {cwd}")
    }

    @Test func missingContextValuesRenderEmpty() {
        let template = TerminalBadgeTemplate(rawValue: "{workspace}/{tab}#{tabIndex}")
        let empty = TerminalBadgeContext()
        #expect(template.render(context: empty) == "/#")
    }

    @Test func emptyTemplateRendersEmpty() {
        let template = TerminalBadgeTemplate(rawValue: "")
        #expect(template.render(context: fullContext).isEmpty)
    }

    @Test func unbalancedOpenBraceIsLiteral() {
        let template = TerminalBadgeTemplate(rawValue: "{workspace} {oops")
        #expect(template.render(context: fullContext) == "feature/login {oops")
    }

    @Test func loneBracesArePreserved() {
        let template = TerminalBadgeTemplate(rawValue: "a {} b } c")
        // "{}" is an unknown (empty-name) token → preserved; lone "}" preserved.
        #expect(template.render(context: fullContext) == "a {} b } c")
    }

    @Test func adjacentPlaceholdersConcatenate() {
        let template = TerminalBadgeTemplate(rawValue: "{workspace}{tab}")
        #expect(template.render(context: fullContext) == "feature/loginclaude")
    }

    @Test func nestedOpenBraceTreatsOuterAsLiteral() {
        // "{ {tab} }" — the outer "{" has a nested "{", so it is copied as a
        // literal and the inner {tab} still substitutes.
        let template = TerminalBadgeTemplate(rawValue: "{ {tab} }")
        #expect(template.render(context: fullContext) == "{ claude }")
    }

    @Test func repeatedPlaceholderSubstitutesEachOccurrence() {
        let template = TerminalBadgeTemplate(rawValue: "{tab} {tab}")
        #expect(template.render(context: fullContext) == "claude claude")
    }
}
