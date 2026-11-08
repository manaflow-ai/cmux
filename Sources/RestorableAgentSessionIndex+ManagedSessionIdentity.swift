import Foundation

extension RestorableAgentSessionIndex.Entry {
    /// Returns this observation only when its kind and canonical session identity match.
    func matchingAgentSession(kind: String, sessionId: String) -> Self? {
        guard snapshot.kind.rawValue == kind,
              ManagedAgentSessionIdentity.sessionIDsMatch(
                  kind: kind,
                  lhs: snapshot.sessionId,
                  rhs: sessionId
              ) else {
            return nil
        }
        return self
    }
}
