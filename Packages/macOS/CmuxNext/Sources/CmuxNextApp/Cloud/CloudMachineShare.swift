import AppKit
import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextCloud
import CmuxNextPalette

/// Sharing a team Cloud machine's app-started chats with a teammate (Leo, 2026-10-31: "but what's
/// the sharing flow? we can't simply block always. we need to be able to get stuff running asap.").
/// A grant (classic `/api/vm/{id}/chat-grants`, ``CloudAPIClient/grantChat(_:to:)``) makes the
/// machine's attach endpoint answer `vmKind: "owner"` to that teammate, and cmux-tui then starts
/// their app chats there (cmux#29107). Two ways in:
///
/// - Share Machine… on the machine's menu (`cloudShareMachine`): a palette page of the team's
///   members, shared ones first; Return shares with the row's teammate or takes it back.
/// - Share with Me on a teammate's machine's refused chat start (the agent pane's
///   `machine.share.self`): the same grant for the signed-in person, for a team admin.
///
/// The server decides who may share (the machine's creator, or a team admin); this only forwards
/// and words its refusals. The ownership answer is read at each link start (``CloudMachineLink``),
/// so after a grant for the signed-in person the machine's link starts again before the reply.
@MainActor
enum CloudMachineShare {
    /// Share with Me: grants the signed-in person chats on `session`'s machine, then renews the
    /// machine's link so its attach answer says `owner` before the page retries the start.
    static func shareWithMe(_ session: CloudMachineSession, cloud: CloudService) async -> AgentPaneMachineShare {
        guard let user = cloud.auth.user?.id else { return .refused(code: "not_signed_in", message: CloudStrings.signInFirst) }
        // Grants live on the classic Cloud API; a machine on the Cloud app server link has none yet.
        guard session.link != nil else { return .refused(code: "unavailable", message: CloudShareStrings.notCloudMachine) }
        do {
            try await cloud.api.grantChat(session.machineID, to: user)
        } catch {
            // Not allowed to share, but the owner may already have shared it with this person (Ask
            // the Owner): then this click only has to make the link ask for its owner answer again.
            guard case .refused(CloudMachineShareRefusal.forbidden.code, _) = refusal(error),
                  (try? await cloud.api.chatGrants(session.machineID))?.contains(where: { $0.userId == user }) == true else {
                return refusal(error)
            }
        }
        if let link = session.link {
            await link.renew()
            _ = try? await link.socketPath()
        }
        return .shared
    }

    /// Shares `session`'s machine with `teammate`, or takes the share back.
    static func set(_ shared: Bool, teammate: String, on session: CloudMachineSession, cloud: CloudService) async throws {
        if shared { try await cloud.api.grantChat(session.machineID, to: teammate) } else { try await cloud.api.revokeChat(session.machineID, from: teammate) }
        // Shared with oneself (a team admin on a teammate's machine): this Mac's link asks again.
        if teammate == cloud.auth.user?.id, let link = session.link { await link.renew() }
    }

    /// The machine's team roster with each teammate's share, for the page and `cloud share-machine`.
    static func roster(_ session: CloudMachineSession, cloud: CloudService) async throws -> CloudMachineShareRoster {
        guard let team = cloud.auth.teamID else { throw ActionFailure(message: CloudShareStrings.noTeam) }
        let grants = try await cloud.api.chatGrants(session.machineID)
        let detail = try await cloud.auth.teamDetail(id: team)
        return CloudMachineShareRoster(members: detail.members, viewer: detail.viewer, creator: session.machine.createdBy, grants: grants)
    }

    /// Share Machine…: one row per teammate. Return shares with them, or takes a share back; the
    /// palette closes and a toast says what changed.
    static func page(_ session: CloudMachineSession, services: AppServices) -> PalettePageSpec {
        let cloud = services.cloud, machine = session.machine.title, registry = services.registry
        let provider = AsyncPaletteProvider(id: "cloud.shareMachine") {
            do {
                let roster = try await roster(session, cloud: cloud)
                return roster.rows.map { row in item(row, machine: machine, session: session, services: services) }
            } catch {
                registry.refuse(message(error))
                return []
            }
        }
        return PalettePageSpec(id: "cloud.shareMachine", title: CloudShareStrings.pageTitle(machine),
                               placeholder: CloudShareStrings.placeholder, symbol: "person.2", providers: [provider])
    }

    private static func item(_ row: CloudMachineShareRoster.Row, machine: String, session: CloudMachineSession, services: AppServices) -> PaletteItem {
        let cloud = services.cloud, registry = services.registry
        let toggle = PaletteCommand(id: row.shared ? "stop" : "share", title: row.shared ? CloudShareStrings.stopSharing : CloudShareStrings.share,
                                    symbol: row.shared ? "person.crop.circle.badge.minus" : "person.crop.circle.badge.plus",
                                    isDestructive: row.shared, effect: .perform {
            // task-owner: one share change, reported as a toast or a refusal
            Task { @MainActor in
                do {
                    try await set(!row.shared, teammate: row.userID, on: session, cloud: cloud)
                    let text = row.shared ? CloudShareStrings.stopped(row.name, machine) : CloudShareStrings.shared(row.name, machine)
                    CloudPresenter.show(text, "", in: NSApp.keyWindow)
                } catch {
                    registry.refuse(message(error))
                }
            }
        })
        return PaletteItem(id: "cloud.share:\(row.userID)", title: row.name,
                           subtitle: row.shared ? CloudShareStrings.canStartChats : row.email,
                           symbol: row.shared ? "checkmark.circle.fill" : "person.crop.circle",
                           keywords: [row.email, row.userID].compactMap { $0 }, primary: toggle)
    }

    /// The page's refusal for a failed change: the Cloud API's code, in this app's words.
    static func refusal(_ error: any Error) -> AgentPaneMachineShare {
        if case .http(_, let code, _, _, _) = error as? CloudAPIError, let refusal = CloudMachineShareRefusal(code: code) {
            return .refused(code: refusal.code, message: CloudShareStrings.refusal(refusal))
        }
        return .refused(code: "failed", message: message(error))
    }

    static func message(_ error: any Error) -> String {
        if case .http(_, let code, _, _, _) = error as? CloudAPIError, let refusal = CloudMachineShareRefusal(code: code) {
            return CloudShareStrings.refusal(refusal)
        }
        return CloudStrings.errorText(error)
    }
}
