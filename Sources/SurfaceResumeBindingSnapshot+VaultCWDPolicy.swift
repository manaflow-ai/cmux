import Foundation

extension SurfaceResumeBindingSnapshot {
    func registeredVaultCWDPolicy(workingDirectory: String?) -> CmuxVaultAgentCWDPolicy? {
        guard let rawKind = kind?.trimmingCharacters(in: .whitespacesAndNewlines),
              case .custom(let id) = RestorableAgentKind(rawValue: rawKind) else {
            return nil
        }
        return CmuxVaultAgentRegistry.load(workingDirectory: workingDirectory).registration(id: id)?.cwd
    }
}
