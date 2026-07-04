import Foundation

extension SurfaceResumeBindingSnapshot {
    var vaultAgentRegistrationID: String? {
        guard let id = kind?.trimmingCharacters(in: .whitespacesAndNewlines),
              let restorableKind = RestorableAgentKind(rawValue: id) else {
            return nil
        }

        switch restorableKind {
        case .custom, .grok, .pi, .antigravity:
            return restorableKind.rawValue
        case .claude, .codex, .amp, .cursor, .gemini, .kiro, .opencode, .rovodev,
             .hermesAgent, .copilot, .codebuddy, .factory, .qoder:
            return nil
        }
    }
}
