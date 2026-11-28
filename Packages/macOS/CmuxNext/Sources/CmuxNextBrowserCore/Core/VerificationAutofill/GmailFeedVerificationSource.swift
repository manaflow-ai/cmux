public import Foundation

/// Fetches one Gmail inbox feed with the Google sign-in the person already has in cmux's
/// browser: the seam ``GmailFeedVerificationSource`` reads through, so tests pass a fake.
public nonisolated protocol GmailFeedFetching: Sendable {
    /// GETs `https://mail.google.com/mail/u/<index>/feed/atom` with the browser profile's
    /// cookies and returns the body.
    /// - Parameter accountIndex: Gmail's signed-in account slot (`/u/0`, `/u/1`, ...).
    /// - Returns: The response body; nil when the slot is not signed in (401, a sign-in redirect).
    /// - Throws: A network failure.
    func feed(accountIndex: Int) async throws -> Data?
}

/// Reads new mail from Gmail accounts signed in to cmux's browser, through Gmail's inbox feed
/// (plans/cmux-next/email-verification-autofill/DESIGN.md "Gmail in cmux's browser"). No OAuth
/// client, no new credential, nothing stored: the request carries the browser profile's existing
/// Google cookies, from the app process, never from a page.
///
/// The feed lists unread inbox messages (subject, snippet, From address, arrival). The source
/// keeps only entries of opted-in accounts received since the wait started, and never looks at
/// accounts the person did not opt in beyond the feed title that names the slot's account.
///
/// ```swift
/// let source = GmailFeedVerificationSource(fetcher: CEFGmailFeedFetcher(profile: profile))
/// let fake = GmailFeedVerificationSource(fetcher: FakeFetcher())
/// ```
public nonisolated struct GmailFeedVerificationSource: VerificationEmailSource {
    /// Gmail's account slots tried: a browser profile rarely has more signed in.
    public static let maxAccounts = 4

    private let fetcher: any GmailFeedFetching

    /// - Parameter fetcher: Fetches a feed with the browser profile's cookies.
    public init(fetcher: any GmailFeedFetching) {
        self.fetcher = fetcher
    }

    public func emails(receivedSince since: Date, accounts: Set<String>) async throws -> [VerificationEmail] {
        guard !accounts.isEmpty else { return [] }
        var seen = Set<String>()
        var emails: [VerificationEmail] = []
        for index in 0..<Self.maxAccounts {
            guard let data = try await fetcher.feed(accountIndex: index), let feed = GmailInboxFeed.parse(data) else { break }
            // Gmail answers a slot past the last signed-in account with the first one again.
            guard seen.insert(feed.account).inserted else { break }
            guard accounts.contains(feed.account) else { continue }
            for entry in feed.entries where entry.receivedAt >= since {
                emails.append(VerificationEmail(
                    id: "gmail:\(feed.account):\(entry.id)", senderAddress: entry.senderAddress, senderAuthenticated: nil,
                    subject: entry.subject, body: entry.snippet, links: [], receivedAt: entry.receivedAt, account: feed.account
                ))
            }
            if seen.count >= accounts.count, accounts.isSubset(of: seen) { break }
        }
        return emails
    }

    public func availableAccounts() async throws -> [String] {
        var seen: [String] = []
        for index in 0..<Self.maxAccounts {
            guard let data = try await fetcher.feed(accountIndex: index), let feed = GmailInboxFeed.parse(data),
                  !seen.contains(feed.account) else { break }
            seen.append(feed.account)
        }
        return seen
    }
}
