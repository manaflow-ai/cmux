import Foundation

extension SurfaceResumeBindingSnapshot {
    var hasCompleteManagedSessionIdentity: Bool {
        managedSessionIdentity != nil
    }

    func isSameManagedSession(as other: SurfaceResumeBindingSnapshot) -> Bool {
        guard let identity = managedSessionIdentity,
              let otherIdentity = other.managedSessionIdentity else {
            return false
        }
        return identity.kind == otherIdentity.kind &&
            identity.checkpointId == otherIdentity.checkpointId
    }

    private var managedSessionIdentity: (kind: String, checkpointId: String)? {
        guard source == "agent-hook",
              let kind = kind?.trimmingCharacters(in: .whitespacesAndNewlines),
              !kind.isEmpty,
              let checkpointId = checkpointId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !checkpointId.isEmpty else {
            return nil
        }
        return (kind, checkpointId)
    }
}
