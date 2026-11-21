/// Where the Chief tab's setup is (`debug.home`'s `home_workspace.chief_step`), apart from the
/// home workspace's own step (`step`: `ensure_home`, the dock), which runs beside it and used to
/// share one field with it: `step` could read "waiting for the chief owner" after the owner had
/// connected (air-blue, 2026-11-16, `chief_owner.connected` true). The wait for the owner is kept
/// as a state, not a sentence, and read against the owner's live connection when reported.
public enum HomeChiefTabStep: Equatable, Sendable {
    case notStarted
    /// ``HomeService`` waits for the Chief home's owner daemon to connect and serve local conversations.
    case waitingForOwner
    /// A step that names itself (the owner answered, the tab exists, why there is none).
    case reached(String)

    /// What `debug.home` shows: the waiting step says what the owner lacks right now, so it never reads
    /// "waiting" for an owner that is connected and serving.
    /// - Parameters:
    ///   - session: the owner's daemon session (`chief_owner.session`).
    ///   - connected: the owner has a connection (`chief_owner.connected`).
    ///   - servesLocal: the owner serves local conversations (`home_workspace.local_conversations`).
    public func text(session: String, connected: Bool, servesLocal: Bool) -> String {
        switch self {
        case .notStarted: "not started"
        case .reached(let text): text
        case .waitingForOwner:
            switch (connected, servesLocal) {
            case (false, _): "waiting for the chief owner \(session) to connect"
            case (true, false): "chief owner \(session) connected; waiting for it to serve local conversations"
            case (true, true): "chief owner \(session) connected; reading its conversations"
            }
        }
    }
}
