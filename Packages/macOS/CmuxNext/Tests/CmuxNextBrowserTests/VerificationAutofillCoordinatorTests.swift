@testable import CmuxNextBrowser
import Foundation
import Testing

/// The flow end to end with a mock tab and a fake mail source (DESIGN.md): a waiting page, an
/// email from its site, the offer in the tab's prompt bar, and what Fill Code, Open Link and
/// Not Now do. The source is read only while the feature is on and a page waits.
@MainActor @Suite(.serialized) struct VerificationAutofillCoordinatorTests {
    actor FakeSource: VerificationEmailSource {
        var emails: [VerificationEmail] = []
        private(set) var reads: [Date] = []
        func set(_ emails: [VerificationEmail]) { self.emails = emails }
        func emails(receivedSince since: Date) async throws -> [VerificationEmail] {
            reads.append(since)
            return emails.filter { $0.receivedAt >= since }
        }
    }

    final class Switch { var on = true }

    static let start = Date(timeIntervalSince1970: 1_800_000_000)
    let source = FakeSource()
    let enabled = Switch()
    let coordinator: VerificationAutofillCoordinator

    init() {
        let list = PublicSuffixList.bundled() ?? PublicSuffixList(listText: "")
        let enabled = enabled
        coordinator = VerificationAutofillCoordinator(
            inbox: VerificationInbox(policy: VerificationOfferPolicy(publicSuffixes: list)), source: source,
            isEnabled: { enabled.on }, now: { Self.start.addingTimeInterval(30) }, pollInterval: .seconds(3600)
        )
    }

    static func tab(_ url: String = "https://github.com/sessions/verified-device") -> MockBrowserTab {
        MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: URL(string: url)))
    }

    static func email(id: String = "m1", body: String = "Your verification code is 482913.", links: [String] = []) -> VerificationEmail {
        VerificationEmail(id: id, senderAddress: "noreply@github.com", senderAuthenticated: true, subject: "", body: body,
                          links: links.compactMap(URL.init(string:)), receivedAt: start.addingTimeInterval(10))
    }

    static func offer(on tab: MockBrowserTab) -> VerificationOffer? {
        guard let prompt = tab.pendingPrompts.last, case .verificationOffer(let offer) = prompt.kind else { return nil }
        return offer
    }

    static func evaluated(_ tab: MockBrowserTab) -> [String] {
        tab.commands.compactMap { if case .evaluate(let script) = $0 { script } else { nil } }
    }

    @Test func anEmailFromThePagesSiteShowsItsCodeInThePromptBar() async {
        let tab = Self.tab()
        await source.set([Self.email()])
        coordinator.pageWaiting(tab)
        await coordinator.pollOnce()
        #expect(Self.offer(on: tab)?.code == "482913")
        #expect(tab.pendingPrompts.last?.origin == "https://github.com")
    }

    @Test func fillCodeTypesTheCodeOnceAndNeverAgain() async {
        let tab = Self.tab()
        tab.evaluationResult = .bool(true)
        await source.set([Self.email()])
        coordinator.pageWaiting(tab)
        await coordinator.pollOnce()
        tab.pendingPrompts.last?.respond(.accept)
        await coordinator.settle()
        #expect(Self.evaluated(tab).count == 1)
        #expect(Self.evaluated(tab).first?.contains("482913") == true)
        #expect(tab.pendingPrompts.isEmpty)
        coordinator.pageWaiting(tab)
        await coordinator.pollOnce()
        #expect(tab.pendingPrompts.isEmpty)
    }

    @Test func openLinkLoadsTheLinkInTheSameTab() async {
        let tab = Self.tab("https://github.com/signup")
        await source.set([Self.email(body: "Confirm your email address.", links: ["https://github.com/users/confirm_verification/abc"])])
        coordinator.pageWaiting(tab)
        await coordinator.pollOnce()
        tab.pendingPrompts.last?.respond(.allowOnce)
        await coordinator.settle()
        #expect(tab.commands.contains(.load(URL(string: "https://github.com/users/confirm_verification/abc")!)))
    }

    @Test func notNowDropsTheOffer() async {
        let tab = Self.tab()
        await source.set([Self.email()])
        coordinator.pageWaiting(tab)
        await coordinator.pollOnce()
        tab.pendingPrompts.last?.respond(.cancel)
        await coordinator.settle()
        await coordinator.pollOnce()
        #expect(tab.pendingPrompts.isEmpty)
        #expect(Self.evaluated(tab).isEmpty)
    }

    /// The navigation race: the tab went to another site before the click.
    @Test func fillCodeAfterTheTabLeftTheSiteFillsNothing() async {
        let tab = Self.tab()
        await source.set([Self.email()])
        coordinator.pageWaiting(tab)
        await coordinator.pollOnce()
        tab.load(URL(string: "https://evil.com/")!)
        tab.pendingPrompts.last?.respond(.accept)
        await coordinator.settle()
        #expect(Self.evaluated(tab).isEmpty)
    }

    @Test func anotherSitesPageGetsNothing() async {
        let tab = Self.tab("https://evil.com/login")
        await source.set([Self.email()])
        coordinator.pageWaiting(tab)
        await coordinator.pollOnce()
        #expect(tab.pendingPrompts.isEmpty)
    }

    @Test func anAgentDrivenTabGetsNothing() async {
        let tab = Self.tab()
        tab.markAgentDriven()
        await source.set([Self.email()])
        coordinator.pageWaiting(tab)
        await coordinator.pollOnce()
        #expect(tab.pendingPrompts.isEmpty)
    }

    @Test func aNewerEmailReplacesTheShownOffer() async {
        let tab = Self.tab()
        tab.evaluationResult = .bool(true)
        await source.set([Self.email(id: "m1", body: "Your code is 111111.")])
        coordinator.pageWaiting(tab)
        await coordinator.pollOnce()
        await source.set([Self.email(id: "m1", body: "Your code is 111111."), Self.email(id: "m2", body: "Your code is 222222.")])
        await coordinator.pollOnce()
        #expect(tab.pendingPrompts.count == 1)
        #expect(Self.offer(on: tab)?.code == "222222")
        tab.pendingPrompts.last?.respond(.accept)
        await coordinator.settle()
        #expect(Self.evaluated(tab).first?.contains("222222") == true)
    }

    @Test func theSourceIsNotReadWhileTheFeatureIsOff() async {
        enabled.on = false
        let tab = Self.tab()
        coordinator.pageWaiting(tab)
        await coordinator.pollOnce()
        #expect(await source.reads.isEmpty)
        #expect(tab.pendingPrompts.isEmpty)
    }

    @Test func theSourceIsNotReadWhenNoPageWaits() async {
        await coordinator.pollOnce()
        #expect(await source.reads.isEmpty)
    }

    @Test func theSourceReadsFromTheLookbackBeforeTheWait() async {
        let tab = Self.tab()
        coordinator.pageWaiting(tab)
        await coordinator.pollOnce()
        #expect(await source.reads == [Self.start.addingTimeInterval(30 - VerificationOfferPolicy.lookback)])
    }

    @Test func turningTheFeatureOffWithdrawsTheOffer() async {
        let tab = Self.tab()
        await source.set([Self.email()])
        coordinator.pageWaiting(tab)
        await coordinator.pollOnce()
        enabled.on = false
        coordinator.settingChanged()
        #expect(tab.pendingPrompts.isEmpty)
    }
}
