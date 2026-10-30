/// Asks the person to confirm one team invite before anything is sent. The
/// App shows ``TeamInviteConsentPanel``; tests answer from a script.
@MainActor
public protocol TeamInviteConsenting: AnyObject {
    /// Shows the confirmation and returns the person's answer.
    func ask(_ request: TeamInviteRequest) async -> TeamInviteAnswer
}
