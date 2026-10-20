/// Answers a Chief permission that the Home approval card shows (a `question` part of harness
/// `chief` with a `permission`): Allow or Deny reaches the asking acpmux session as the person.
///
/// acpmux takes an allow only from the person's own connection (acpmux `hub/person.rs`): the
/// Mac app's, never the Chief's relay of a chat reply. So the card answers acpmux itself
/// through this, and only then marks the part answered in the conversation (`question.answer`).
/// The render core has no acpmux client; the Mac app passes one. A host without one passes none
/// and the card's Allow says it cannot answer here.
public protocol HomeApprovalDeciding: AnyObject, Sendable {
    /// Answers `permission` of acpmux session `session` for the Chief participant `chief` (the
    /// card's author, `agent_mux` for the default Chief): only that Chief's acpmux, and only a
    /// session that Chief runs (its turn or one of its subagents). Throws when acpmux refused,
    /// the session is not that Chief's, or the prompt is no longer pending; the error's
    /// description is shown on the card.
    @MainActor
    func decide(chief: String, session: String, permission: String, allow: Bool) async throws
}
