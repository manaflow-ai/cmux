import Foundation
import CMUXAgentLaunch

extension ControlSurfaceResumeTarget {
    /// Resolves the built-in cwd-option identity available to a binding-only restore.
    ///
    /// Registry-owned spellings such as `kimi` may identify either a native
    /// agent or a user Vault registration. A matching native snapshot is the
    /// only safe evidence for enabling its provider-specific short option;
    /// otherwise only non-overridable built-ins are unambiguous.
    func builtInAgentKindForBindingSanitization(
        binding: SurfaceResumeBindingSnapshot,
        normalizedKind: String
    ) -> String? {
        let normalized = normalizedKind
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if let snapshot = restorableAgent,
           snapshot.kind.rawValue
               .trimmingCharacters(in: .whitespacesAndNewlines)
               .lowercased() == normalized,
           let checkpointID = binding.checkpointId?
               .trimmingCharacters(in: .whitespacesAndNewlines),
           !checkpointID.isEmpty,
           ManagedAgentSessionIdentity.sessionIDsMatch(
               kind: normalized,
               lhs: checkpointID,
               rhs: snapshot.sessionId
           ),
           let snapshotBuiltInKind = snapshot.workingDirectoryOptionPolicyBuiltInKind {
            return snapshotBuiltInKind
        }
        // Without a matching native snapshot, the persisted kind may be a
        // custom Vault registration reusing a built-in spelling.  Do not infer
        // provider-specific cwd flags from the raw binding id; preserving an
        // ambiguous option is safer than stripping a custom profile selector.
        return nil
    }

}
