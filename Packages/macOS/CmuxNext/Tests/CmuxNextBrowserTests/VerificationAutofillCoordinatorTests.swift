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

    /// A source whose first read waits until the test releases it: a slow Mail script.
    actor GatedSource: VerificationEmailSource {
        private(set) var reads = 0
        private(set) var inFlight = 0
        private(set) var mostInFlight = 0
        private var gate: CheckedContinuation<Void, Never>?
        func emails(receivedSince since: Date) async throws -> [VerificationEmail] {
            reads += 1
            inFlight += 1
            mostInFlight = max(mostInFlight, inFlight)
            if reads == 1 { await withCheckedContinuation { gate = $0 } }
            inFlight -= 1
            return []
        }
        func release() {
            gate?.resume()
            gate = nil
        }
    }

    /// Another page starting to wait during a slow read arms no second read (one osascript at a
    /// time, as the loop before DemandTimer did): an older read finishing last would replace a
    /// newer offer with an older code.
    @Test func aSlowReadIsNeverOverlappedByAnotherRead() async throws {
        let source = GatedSource()
        let enabled = Switch()
        let list = PublicSuffixList.bundled() ?? PublicSuffixList(listText: "")
        let coordinator = VerificationAutofillCoordinator(
            inbox: VerificationInbox(policy: VerificationOfferPolicy(publicSuffixes: list)), source: source,
            isEnabled: { enabled.on }, now: { Self.start.addingTimeInterval(30) }, clock: ImmediateClock(),
            pollInterval: .seconds(3)
        )
        let first = Self.tab(), second = Self.tab("https://github.com/login/device")
        coordinator.pageWaiting(first)
        var tries = 0
        while await source.reads < 1, tries < 500 { tries += 1; try await Task.sleep(for: .milliseconds(2)) }
        #expect(await source.reads == 1, "the first deadline started a read")
        coordinator.pageWaiting(second)
        tries = 0
        while await source.reads < 2, tries < 100 { tries += 1; try await Task.sleep(for: .milliseconds(2)) }
        let overlapping = await source.mostInFlight
        enabled.on = false
        await source.release()
        #expect(overlapping == 1, "a second read started while the first still ran")
        _ = (first, second)
    }
}

/// A clock whose sleeps end at once, so each poll deadline fires on the next task turn.
nonisolated private struct ImmediateClock: Clock {
    nonisolated struct Instant: InstantProtocol {
        var offset: Duration = .zero

        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    var now: Instant { Instant() }
    var minimumResolution: Duration { .nanoseconds(1) }

    func sleep(until _: Instant, tolerance _: Duration?) async throws {}
}
