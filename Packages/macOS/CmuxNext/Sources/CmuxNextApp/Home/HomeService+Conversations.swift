import CmuxHomeCore
import CmuxNextHome
import Foundation

/// The Home page's conversation actions (New Message, Invite, New Chief,
/// Archive Chief), shared by the page's sheets, the palette and the CLI.
extension HomeService {
    var composer: HomeComposer {
        let store = homeStore
        return HomeComposer { op in try await store.perform(op) }
    }

    /// The people New Message offers: team members, then people of the
    /// user's DMs. The cloud source learns their names for new groups.
    func contacts() -> [HomeContact] {
        let me = homeStore.me?.id ?? homeSource.me.id
        let team = directory.teamMembers
        cloudSource.remember(team.map { Participant(id: $0.id, kind: .human, displayName: $0.name) })
        return HomeContact.merged(team: team, connections: HomeContact.connections(in: homeStore.rows, me: me))
    }

    /// Starts a DM or a group; the page shows it once the inbox lists it.
    func startConversation(_ recipients: [HomeRecipient], title: String) async -> HomeComposeOutcome {
        let outcome = await composer.start(recipients, title: title)
        if case .opened(let id) = outcome { pendingSelection = id }
        return outcome
    }

    func invite(_ address: ContactAddress) async -> HomeComposeOutcome {
        await composer.invite(address)
    }

    /// Creates another Chief; its main conversation shows once the inbox lists it.
    func createChief(named name: String) async -> HomeComposeOutcome {
        do {
            let record = try await directory.createChief(named: name)
            let id = record.mainConversation.map { ConversationID($0) }
            pendingSelection = id
            return id.map { HomeComposeOutcome.opened($0) } ?? .invited(nil)
        } catch FeedServiceError.signedOut {
            return .offline
        } catch FeedServiceError.owner(let code, let message) {
            return .refused(code == "policy.denied" || code == "validation.invalid" ? message : HomeConversationStrings.inviteRefusal(code))
        } catch {
            return .refused("")
        }
    }

    /// Archives one of my Chiefs (not the default one); nil when it worked,
    /// else why not.
    func archiveChief(_ id: String) async -> String? {
        if directory.chief(for: ParticipantID(id)) == nil { await directory.refreshChiefs() }
        do {
            try await directory.archiveChief(id)
            return nil
        } catch FeedServiceError.owner(let code, let message) {
            return code == "chief_is_default" ? HomeStrings.archiveDefaultChief : message
        } catch {
            return HomeStrings.archiveFailed
        }
    }

    /// The Chief record behind a conversation row, when the row is a DM
    /// with one of my cloud Chiefs (the local Chief is never archived).
    func chief(of row: InboxRow) -> HomeChiefRecord? {
        guard row.kind == .chief, let me = homeStore.me?.id,
              let agent = row.summary.participants.first(where: { $0.id != me && $0.isChief }) else { return nil }
        return directory.chief(for: agent.id)
    }
}
