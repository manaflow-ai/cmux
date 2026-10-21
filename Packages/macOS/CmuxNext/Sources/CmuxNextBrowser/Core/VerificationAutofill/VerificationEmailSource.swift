public import Foundation

/// A mail source the person opted into (slice 2: Mail.app, ``MailAppVerificationSource``). The
/// ``VerificationAutofillCoordinator`` reads it only while the feature is on and a page waits,
/// and only for messages received since the wait started.
public protocol VerificationEmailSource: Sendable {
    /// The emails received since `since`, read once per call. A source keeps nothing.
    /// - Parameter since: The earliest arrival time to return.
    /// - Returns: The emails, any order.
    func emails(receivedSince since: Date) async throws -> [VerificationEmail]
}
