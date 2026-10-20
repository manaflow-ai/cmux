import CmuxHomeRender
import CmuxNextAgentPane
import CmuxNextHomeEngine
import Foundation

/// The Home approval card's Allow and Deny for this Mac's Chiefs (CmuxHomeRender
/// ``HomeApprovalDeciding``). The card's author names its Chief: the default Chief
/// (`agent_mux`) runs in this build's Chief home, a named Chief in its own brain home
/// (``ChiefHome/brainHome(muxHome:chief:)``). Only that home's acpmux is asked, and
/// ``AcpmuxApprovalAnswerer`` answers there as the person only for a session that Chief runs
/// (its turn or one of its subagents), so a card can never answer another Chief's request or a
/// session the Chief does not own.
@MainActor
final class ChiefApprovalDecider: HomeApprovalDeciding {
    private let home: ChiefHome

    init(home: ChiefHome) {
        self.home = home
    }

    func decide(chief: String, session: String, permission: String, allow: Bool) async throws {
        let brain = Self.brainHome(of: chief, in: home)
        guard let environment = ChiefHomeAcpmux.environment(home: brain) else {
            throw AcpmuxApprovalAnswerer.Refusal.noDaemon
        }
        let file = brain.muxHome.appendingPathComponent("optchat", isDirectory: true).appendingPathComponent("home-id")
        // The pinned id is read off the main actor (a small file, but still a disk read).
        let pinned = await Task.detached { Self.pinnedID(try? String(contentsOf: file, encoding: .utf8)) }.value
        try await AcpmuxApprovalAnswerer(environment: environment)
            .answer(session: session, permission: permission, allow: allow,
                    chiefHomeID: pinned ?? Self.pathHomeID(brain))
    }

    /// The home of Chief participant `chief`: `home` for the default Chief, else its brain home.
    static func brainHome(of chief: String, in home: ChiefHome) -> ChiefHome {
        let named = chief == HomeChiefAvatars.defaultChief ? nil : chief
        return ChiefHome(root: ChiefHome.brainHome(muxHome: home.muxHome, chief: named), isolated: home.isolated)
    }

    /// optchat-chief `paths::home_id` of `home` when no id is pinned in `optchat/home-id` (a home
    /// moved by `cmux chief move` keeps its pinned id): the FNV-1a of the path, the tag its
    /// sessions carry (`cmux.chief`, `mux.parent` = `optchat-chief:<id>`).
    static func pathHomeID(_ home: ChiefHome) -> String {
        String(ChiefHomeAcpmux.host(muxHome: home.muxHome).dropFirst("chief:".count))
    }

    /// A pinned home id: 8 lowercase hex digits, else nil.
    nonisolated static func pinnedID(_ text: String?) -> String? {
        guard let id = text?.trimmingCharacters(in: .whitespacesAndNewlines), id.count == 8,
              id.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return nil }
        return id
    }
}
