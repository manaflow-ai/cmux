public import Foundation

extension CombinedVerificationSource {
    /// The mailboxes email code AutoFill reads (plans/cmux-next/email-verification-autofill/DESIGN.md
    /// "Sources"): Gmail accounts signed in to cmux's browser, read through their inbox feed inside
    /// the waiting page's Chromium profile, then the Mail app's accounts. Debug builds put a fixture
    /// mail file first when `CMUX_NEXT_VERIFICATION_FIXTURE_MAIL` names one (a live check with no real
    /// mailbox).
    /// - Parameters:
    ///   - waitingTabs: The tabs that wait for a code now; the Gmail feed is fetched in the first
    ///     Chromium one's profile.
    ///   - environment: The process environment (the debug fixture path).
    /// - Returns: The sources, read in order, behind the coordinator's account opt-in.
    public static func standard(
        waitingTabs: @escaping @MainActor @Sendable () -> [any BrowserTab],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> CombinedVerificationSource {
        var sources: [any VerificationEmailSource] = []
        #if DEBUG
        if let path = environment["CMUX_NEXT_VERIFICATION_FIXTURE_MAIL"], !path.isEmpty {
            sources.append(DebugVerificationFixtureSource(url: URL(fileURLWithPath: path)))
        }
        #endif
        sources.append(GmailFeedVerificationSource(fetcher: CEFGmailFeedFetcher { waitingTabs().first { $0 is CEFTab } }))
        sources.append(MailAppVerificationSource())
        return CombinedVerificationSource(sources)
    }
}
