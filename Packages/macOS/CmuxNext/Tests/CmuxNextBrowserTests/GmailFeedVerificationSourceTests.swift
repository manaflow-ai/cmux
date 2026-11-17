@testable import CmuxNextBrowser
import Foundation
import Testing

/// The Gmail source (DESIGN.md "Gmail in cmux's browser"): it reads Gmail's inbox feed with the
/// browser's existing sign-in, returns only opted-in accounts' mail received since the wait
/// started, takes the sender from the feed's author address, and stops at the last signed-in slot.
@Suite struct GmailFeedVerificationSourceTests {
    actor FakeFetcher: GmailFeedFetching {
        let feeds: [Int: String]
        private(set) var asked: [Int] = []
        init(_ feeds: [Int: String]) { self.feeds = feeds }
        func feed(accountIndex: Int) async throws -> Data? {
            asked.append(accountIndex)
            return feeds[accountIndex].map { Data($0.utf8) }
        }
    }

    static let since = Date(timeIntervalSince1970: 1_800_000_000) // 2027-01-15T08:00:00Z

    static func feed(_ account: String, _ entries: [(id: String, title: String, summary: String, from: String, issued: String)]) -> String {
        let items = entries.map { entry in
            """
            <entry><title>\(entry.title)</title><summary>\(entry.summary)</summary>
            <link rel="alternate" href="https://mail.google.com/mail/u/0?account_id=x&amp;message_id=\(entry.id)&amp;view=conv&amp;extsrc=atom" type="text/html"/>
            <modified>\(entry.issued)</modified><issued>\(entry.issued)</issued><id>tag:gmail.google.com,2004:\(entry.id)</id>
            <author><name>Slack &lt;security@evil.com&gt;</name><email>\(entry.from)</email></author></entry>
            """
        }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8"?><feed version="0.3" xmlns="http://purl.org/atom/ns#">
        <title>Gmail - Inbox for \(account)</title><tagline>New messages in your Gmail Inbox</tagline>
        <fullcount>\(entries.count)</fullcount><link rel="alternate" href="https://mail.google.com/mail" type="text/html"/>
        <modified>2027-01-15T08:01:00Z</modified>\(items)</feed>
        """
    }

    static let slack = (id: "1849", title: "Slack confirmation code: Q7K-2PL",
                        summary: "Confirm your email address Your confirmation code is below — enter it in your open browser window. Q7K-2PL",
                        from: "no-reply@slack.com", issued: "2027-01-15T08:00:30Z")
    static let old = (id: "1700", title: "Your code", summary: "Your code is 111111", from: "no-reply@slack.com", issued: "2027-01-15T07:00:00Z")

    @Test func readsAnOptedInAccountsNewMail() async throws {
        let fetcher = FakeFetcher([0: Self.feed("Lawrence@cmux.com", [Self.slack, Self.old])])
        let emails = try await GmailFeedVerificationSource(fetcher: fetcher).emails(receivedSince: Self.since, accounts: ["lawrence@cmux.com"])
        let email = try #require(emails.first)
        #expect(emails.count == 1)
        #expect(email.senderAddress == "no-reply@slack.com")
        #expect(email.account == "lawrence@cmux.com")
        #expect(email.id == "gmail:lawrence@cmux.com:tag:gmail.google.com,2004:1849")
        #expect(email.senderAuthenticated == nil)
        #expect(email.receivedAt == Date(timeIntervalSince1970: 1_800_000_030))
        #expect(VerificationMessageParser().parse(email).codes == ["Q7K2PL"])
    }

    /// The sender is the feed's author address, never the display name a sender chose.
    @Test func theSenderIsTheAuthorAddressNotTheName() async throws {
        let fetcher = FakeFetcher([0: Self.feed("you@example.com", [Self.slack])])
        let email = try #require(try await GmailFeedVerificationSource(fetcher: fetcher).emails(receivedSince: Self.since, accounts: ["you@example.com"]).first)
        #expect(email.senderAddress == "no-reply@slack.com")
    }

    @Test func anotherAccountsMailIsNeverReturned() async throws {
        let fetcher = FakeFetcher([0: Self.feed("personal@gmail.com", [Self.slack]), 1: Self.feed("work@example.com", [Self.slack])])
        let emails = try await GmailFeedVerificationSource(fetcher: fetcher).emails(receivedSince: Self.since, accounts: ["work@example.com"])
        #expect(emails.map(\.account) == ["work@example.com"])
    }

    /// Gmail answers a slot past the last account with the first account again: the source stops.
    @Test func stopsAtTheLastSignedInSlot() async throws {
        let first = Self.feed("you@example.com", [])
        let fetcher = FakeFetcher([0: first, 1: first, 2: first])
        #expect(try await GmailFeedVerificationSource(fetcher: fetcher).availableAccounts() == ["you@example.com"])
        #expect(await fetcher.asked == [0, 1])
    }

    @Test func noAccountsFetchesNothing() async throws {
        let fetcher = FakeFetcher([0: Self.feed("you@example.com", [Self.slack])])
        #expect(try await GmailFeedVerificationSource(fetcher: fetcher).emails(receivedSince: Self.since, accounts: []).isEmpty)
        #expect(await fetcher.asked.isEmpty)
    }

    /// A sign-in page or any other document is not a feed.
    @Test(arguments: ["<html><body>Sign in</body></html>", "", "<feed><title>Inbox</title></feed>"])
    func aNonFeedIsNotRead(body: String) {
        #expect(GmailInboxFeed.parse(Data(body.utf8)) == nil)
    }

    @Test func anEntryDescriptionIsRedacted() throws {
        let feed = try #require(GmailInboxFeed.parse(Data(Self.feed("you@example.com", [Self.slack]).utf8)))
        let entry = try #require(feed.entries.first)
        #expect(!String(describing: entry).contains("Q7K"))
        #expect(!String(reflecting: entry).contains("Q7K"))
    }
}
