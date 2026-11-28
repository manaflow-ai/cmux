public import Foundation

/// A mail source (``MailAppVerificationSource``, ``GmailFeedVerificationSource``). The
/// ``VerificationAutofillCoordinator`` reads it only while the feature is on and a page waits,
/// only for messages received since the wait started, and only for the accounts the person
/// opted in (plans/cmux-next/email-verification-autofill/DESIGN.md "Email sources").
public nonisolated protocol VerificationEmailSource: Sendable {
    /// The emails received since `since` in the opted-in `accounts`, read once per call. A source
    /// keeps nothing.
    /// - Parameters:
    ///   - since: The earliest arrival time to return.
    ///   - accounts: The opted-in mailbox addresses, lowercased; mail of any other account is
    ///     never returned.
    /// - Returns: The emails, any order, each with its ``VerificationEmail/account``.
    func emails(receivedSince since: Date, accounts: Set<String>) async throws -> [VerificationEmail]

    /// The mailbox addresses this source can read, for the Settings list the person opts in from.
    /// Reads no mail.
    func availableAccounts() async throws -> [String]
}

/// Reads every source and joins their mail; one failing source does not hide the others' mail.
public nonisolated struct CombinedVerificationSource: VerificationEmailSource {
    private let sources: [any VerificationEmailSource]

    /// - Parameter sources: The sources, in the order their accounts are listed.
    public init(_ sources: [any VerificationEmailSource]) {
        self.sources = sources
    }

    public func emails(receivedSince since: Date, accounts: Set<String>) async throws -> [VerificationEmail] {
        var emails: [VerificationEmail] = []
        var firstError: (any Error)?
        for source in sources {
            do { emails += try await source.emails(receivedSince: since, accounts: accounts) } catch { firstError = firstError ?? error }
        }
        if emails.isEmpty, let firstError { throw firstError }
        return emails
    }

    public func availableAccounts() async throws -> [String] {
        var accounts: [String] = []
        for source in sources {
            for account in (try? await source.availableAccounts()) ?? [] where !accounts.contains(account) { accounts.append(account) }
        }
        return accounts
    }
}
