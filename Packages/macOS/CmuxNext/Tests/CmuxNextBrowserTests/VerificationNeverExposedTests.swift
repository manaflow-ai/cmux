@testable import CmuxNextBrowser
import Foundation
import Testing

/// The code never reaches an agent, the page, a log or a description before the person accepts
/// it (DESIGN.md "Threat model"): an agent-driven tab gets no offer and cannot accept one shown
/// before an agent took the tab, no script that runs before the click carries the code, and every
/// description of the offer and its prompt is redacted.
@MainActor @Suite(.serialized) struct VerificationNeverExposedTests {
    actor OneEmail: VerificationEmailSource {
        func emails(receivedSince since: Date, accounts: Set<String>) async throws -> [VerificationEmail] {
            [VerificationEmail(id: "m1", senderAddress: "noreply@github.com", senderAuthenticated: true, subject: "Your code",
                               body: "Your verification code is 482913.", links: [], receivedAt: VerificationNeverExposedTests.start.addingTimeInterval(10),
                               account: "you@example.com")]
        }
        func availableAccounts() async throws -> [String] { ["you@example.com"] }
    }

    nonisolated static let start = Date(timeIntervalSince1970: 1_800_000_000)
    let coordinator = VerificationAutofillCoordinator(
        inbox: VerificationInbox(policy: VerificationOfferPolicy(publicSuffixes: PublicSuffixList.bundled() ?? PublicSuffixList(listText: ""))),
        source: OneEmail(), isEnabled: { true }, accounts: { ["you@example.com"] },
        now: { VerificationNeverExposedTests.start.addingTimeInterval(30) }, pollInterval: .seconds(3600)
    )

    static func tab() -> MockBrowserTab {
        MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://github.com/sessions/verified-device")))
    }

    static func scripts(_ tab: MockBrowserTab) -> [String] {
        tab.commands.compactMap { if case .evaluate(let script) = $0 { script } else { nil } }
    }

    /// An agent took the tab after the offer showed: accepting then types nothing, since the
    /// agent could read the field (or press the key itself through automation).
    @Test func aTabAnAgentTookAfterTheOfferFillsNothing() async {
        let tab = Self.tab()
        tab.evaluationResult = .bool(true)
        coordinator.pageWaiting(tab)
        await coordinator.pollOnce()
        let prompt = tab.pendingPrompts.last
        #expect(prompt != nil)
        tab.markAgentDriven()
        prompt?.respond(.accept)
        await coordinator.settle()
        #expect(!Self.scripts(tab).contains { $0.contains("482913") })
    }

    @Test func anAgentDrivenTabNeverGetsAnOffer() async {
        let tab = Self.tab()
        tab.markAgentDriven()
        coordinator.pageWaiting(tab)
        await coordinator.pollOnce()
        #expect(tab.pendingPrompts.isEmpty)
        #expect(!Self.scripts(tab).contains { $0.contains("482913") })
    }

    /// Before the person accepts, nothing that runs in the page carries the code.
    @Test func noPageScriptCarriesTheCodeBeforeTheClick() async {
        let tab = Self.tab()
        coordinator.pageWaiting(tab)
        await coordinator.pollOnce()
        #expect(tab.pendingPrompts.count == 1)
        #expect(!Self.scripts(tab).contains { $0.contains("482913") })
    }

    /// Diagnostics, debug dumps and automation describe the prompt with its kind: no code there.
    @Test func thePromptDescriptionIsRedacted() async throws {
        let tab = Self.tab()
        coordinator.pageWaiting(tab)
        await coordinator.pollOnce()
        let prompt = try #require(tab.pendingPrompts.last)
        #expect(!String(describing: prompt.kind).contains("482913"))
        #expect(!String(reflecting: prompt.kind).contains("482913"))
        #expect(!String(describing: Mirror(reflecting: prompt.kind).children.map(\.value)).contains("482913"))
    }
}
