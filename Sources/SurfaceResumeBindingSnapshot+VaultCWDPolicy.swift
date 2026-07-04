import Foundation

extension SurfaceResumeBindingSnapshot {
    func registeredVaultCWDPolicy(workingDirectory: String?) -> CmuxVaultAgentCWDPolicy? {
        guard let id = kind?.trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty else {
            return nil
        }
        return CmuxVaultAgentRegistry.load(workingDirectory: cwd ?? workingDirectory).registration(id: id)?.cwd
    }
}
