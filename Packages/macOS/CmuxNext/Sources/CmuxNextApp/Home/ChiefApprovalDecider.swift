import CmuxHomeRender
import CmuxNextAgentPane
import CmuxNextHomeEngine
import Foundation

/// The Home approval card's Allow and Deny for this Mac's Chiefs (CmuxHomeRender
/// ``HomeApprovalDeciding``): the asking session runs on a Chief home's acpmux, the default
/// Chief's or a named Chief's (`<home>/c/<id>`, ``ChiefHome/brainHome(muxHome:chief:)``), and
/// ``AcpmuxApprovalAnswerer`` answers it there as the person. The card does not say which Chief
/// asked, so each home is tried in turn; only the one whose acpmux holds that very prompt answers.
@MainActor
final class ChiefApprovalDecider: HomeApprovalDeciding {
    private let home: ChiefHome

    init(home: ChiefHome) {
        self.home = home
    }

    func decide(session: String, permission: String, allow: Bool) async throws {
        var running = false
        for environment in environments() {
            do {
                try await AcpmuxApprovalAnswerer(environment: environment).answer(session: session, permission: permission, allow: allow)
                return
            } catch AcpmuxApprovalAnswerer.Refusal.notPending {
                // This Chief runs but holds no such prompt: another Chief's, or it ended.
                running = true
            } catch AcpmuxApprovalAnswerer.Refusal.noDaemon {}
        }
        throw running ? AcpmuxApprovalAnswerer.Refusal.notPending : AcpmuxApprovalAnswerer.Refusal.noDaemon
    }

    /// The acpmux of the default Chief, then of each named Chief that has a home here.
    private func environments() -> [AcpmuxEnvironment] {
        let named = (try? FileManager.default.contentsOfDirectory(at: home.root.appendingPathComponent("c", isDirectory: true),
                                                                  includingPropertiesForKeys: nil)) ?? []
        let homes = [home] + named.sorted { $0.path < $1.path }.map { ChiefHome(root: $0, isolated: home.isolated) }
        return homes.compactMap(ChiefHomeAcpmux.environment(home:))
    }
}
