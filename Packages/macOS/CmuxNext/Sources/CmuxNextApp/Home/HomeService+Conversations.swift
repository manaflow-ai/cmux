import CmuxHomeCore
import CmuxNextHome
import CmuxNextHomeEngine
import Foundation

/// The Home page's conversation actions (New Message, Invite, New Chief,
/// Archive Chief), shared by the page's sheets, the palette and the CLI.
extension HomeService {
    var composer: HomeComposer {
        let store = homeStore
        return HomeComposer(perform: { op in try await store.perform(op) }, describe: { RefusalStrings.describe($0) })
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

    /// Creates another Chief on `backend`; its main conversation shows once the inbox lists it.
    /// The one create path of the New Chief sheet, the palette and `cmux home new-chief`: an
    /// engine whose Chiefs are this Mac's (UniiChat, Codex: ``ChiefBackend/createsOnThisMac``)
    /// goes to this Mac's Chief owner, Claude to the signed-in account's cloud Chiefs.
    func createChief(named name: String, backend: ChiefBackend = .claude) async -> HomeComposeOutcome {
        backend.createsOnThisMac ? await createLocalChief(named: name, backend: backend) : await createCloudChief(named: name)
    }

    /// `chief.create` on the signed-in account's cloud Chiefs (the default engine).
    private func createCloudChief(named name: String) async -> HomeComposeOutcome {
        do {
            let record = try await directory.createChief(named: name)
            let id = record.mainConversation.map { ConversationID($0) }
            pendingSelection = id
            return id.map { HomeComposeOutcome.opened($0) } ?? .invited(nil)
        } catch FeedServiceError.signedOut {
            return .offline
        } catch FeedServiceError.owner(let code, let message) {
            return code == "policy.denied" || code == "validation.invalid" ? .refused(message) : .refusal(code: code)
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

    /// The Home sidebar's data source (the vendored MessagesLab sidebar reads it):
    /// choosing a row shows its conversation on the Home page, a person starts a DM.
    func makeSidebarSource() -> HomeSidebarSource {
        let store = homeStore
        let source = HomeSidebarSource(
            store: HomePinStore(), inboxes: [homeInbox, homeCloudInbox], account: { [weak self] in self?.pinAccount ?? "local" },
            rows: { [weak self] in TopHomePageView.visible(store.rows, archivedChiefs: self?.directory.archivedChiefs ?? [], me: store.me?.id) },
            me: { store.me?.id }, contacts: { [weak self] in self?.contacts() ?? [] },
            chiefAvatar: { [weak self] in self?.directory.chiefAvatar },
            chiefHarnesses: { [weak self] in self?.directory.chiefHarnesses ?? [:] })
        source.onSelect = { [weak self] id in self?.pendingSelection = id }
        source.onStart = { [weak self] contact in
            // task-owner: one dm.open; the page shows the DM once listed
            Task { _ = await self?.startConversation([.contact(contact)], title: "") }
        }
        source.reloadPins()
        return source
    }

    /// The account this Mac's Home pins and marks are kept under: the signed-in Cloud user, else "local".
    var pinAccount: String {
        let auth = services.cloud.auth
        return auth.user.map { CloudIdentity.workerUserID(stackProjectID: auth.configuration.stackProjectID, stackUserID: $0.id) } ?? "local"
    }

    /// Reads the Chief's avatar for its tile (profile.json's picture, else
    /// its text, else the bundled cat), as the Chief header does.
    func refreshChiefAvatar() {
        let files = HomeChiefFiles(muxHome: HomeBrainHost.muxHome(tag: services.environment.tag))
        // task-owner: one profile read off the main actor; ends when it is set
        Task { [weak self] in
            let avatar = await Task.detached { files.tileAvatar() }.value
            self?.directory.chiefAvatar = avatar ?? HomeHostView.defaultTileAvatar
        }
    }
}
