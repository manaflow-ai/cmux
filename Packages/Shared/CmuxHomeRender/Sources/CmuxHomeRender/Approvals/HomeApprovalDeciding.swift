/// Answers a Chief permission that the Home approval card shows (a `question` part of harness
/// `chief` with a `permission`): Allow or Deny reaches the asking acpmux session as the person.
///
/// acpmux takes an allow only from the person's own connection (acpmux `hub/person.rs`): the
/// Mac app's, never the Chief's relay of a chat reply. So the card answers acpmux itself
/// through this, and only then marks the part answered in the conversation (`question.answer`).
/// The render core has no acpmux client; the Mac app passes one. A host without one passes none
/// and the card's Allow says it cannot answer here.
public protocol HomeApprovalDeciding: AnyObject, Sendable {
    /// Answers `permission` of acpmux session `session`. Throws when acpmux refused or the
    /// prompt is no longer pending; the error's description is shown on the card.
    @MainActor
    func decide(session: String, permission: String, allow: Bool) async throws
}
