import Foundation

extension VerificationAutofillCoordinator {
    /// The app's coordinator: the bundled Public Suffix List, the reviewed sender map, and the
    /// ``CombinedVerificationSource/standard(waitingTabs:environment:)`` mailboxes, whose Gmail feed
    /// is fetched in the profile of this coordinator's first waiting Chromium tab.
    /// - Parameters:
    ///   - isEnabled: Reads `browser.verificationAutofill.enabled` (off by default).
    ///   - accounts: Reads `browser.verificationAutofill.accounts`, the opted-in addresses.
    /// - Returns: A coordinator that reads nothing until a page waits.
    public static func standard(isEnabled: @escaping () -> Bool, accounts: @escaping () -> Set<String>) -> VerificationAutofillCoordinator {
        let owner = WaitingTabsOwner()
        let coordinator = VerificationAutofillCoordinator(
            inbox: VerificationInbox(policy: VerificationOfferPolicy(publicSuffixes: PublicSuffixList.bundled() ?? PublicSuffixList(listText: ""))),
            source: CombinedVerificationSource.standard { owner.coordinator?.waitingTabs ?? [] },
            isEnabled: isEnabled,
            accounts: accounts
        )
        owner.coordinator = coordinator
        return coordinator
    }
}

/// Lets the coordinator's own source read its waiting tabs, which exist only after it is made.
@MainActor
private final class WaitingTabsOwner {
    weak var coordinator: VerificationAutofillCoordinator?
}
