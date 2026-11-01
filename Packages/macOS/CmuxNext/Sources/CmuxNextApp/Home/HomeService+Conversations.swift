import CmuxHomeCore
import CmuxNextChiefPetWiring
import CmuxNextCloud
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextFloating
import CmuxNextHome
import CmuxNextHomeEngine
import CmuxNextHostedChief
import Foundation

/// The Home page's conversation actions (New Message, Invite, New Chief,
/// Archive Chief), shared by the page's sheets, the palette and the CLI.
extension HomeService {
    var composer: HomeComposer {
        let store = homeStore
        return HomeComposer(perform: { op in try await store.perform(op) }, describe: { RefusalStrings.describe($0) })
    }

    /// The people New Message offers: team members, then people of the
    /// user's DMs, then the user's Chiefs (not archived ones, which the list
    /// hides). The cloud source learns their names for new groups.
    func contacts() -> [HomeContact] {
        let me = homeStore.me?.id ?? homeSource.me.id
        let team = directory.teamMembers
        cloudSource.remember(team.map { Participant(id: $0.id, kind: .human, displayName: $0.name) })
        let rows = HomeArchivedChiefs(directory.archivedChiefs, me: me).visible(homeStore.rows)
        return HomeContact.merged(team: team, connections: HomeContact.connections(in: rows, me: me),
                                  agents: HomeContact.agents(in: rows, me: me))
    }

    /// New Message's list before anything is typed: its Chiefs (main first), then the team
    /// (`HomeNewMessageDraft.idleSuggestions`); how each row draws is HomeChiefRoster+NewMessage.
    func newMessageChiefs(_ draft: HomeNewMessageDraft) -> [HomeContact] {
        draft.idleSuggestions(contacts: chiefRoster.mainFirst(contacts(), rows: homeStore.rows))
    }
    func recipientLook(_ recipient: HomeRecipient) -> HomeRecipientLook {
        chiefRoster.look(recipient, rows: homeStore.rows, avatars: chiefFaces,
                         fallback: .chiefDefault,  // each Chief's own pick is in chiefFaces
                         harnesses: directory.chiefHarnesses)
    }

    /// Starts a DM or a group; the page shows it once the inbox lists it.
    func startConversation(_ recipients: [HomeRecipient], title: String, firstMessage: [MessagePart] = []) async -> HomeComposeOutcome {
        let outcome = await composer.start(recipients, title: title, firstMessage: firstMessage)
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

    /// Headless action path: returns the exact durable record created by this
    /// invocation, so concurrent Home actions cannot cross their result ids.
    func createChiefForAction(named name: String, backend: ChiefBackend) async -> HomeActionChiefResult {
        if backend.createsOnThisMac {
            guard let connection else { return .failure(.offline) }
            do {
                let made = try await HomeLocalChiefCreator(connection: connection, me: Self.localUser)
                    .create(name: name, backend: backend)
                pendingSelection = made.conversation
                refreshChiefHarnesses()
                return .success(HomeChiefRecord(id: made.chief, name: name, isDefault: false, rev: 0,
                                                mainConversation: made.conversation.rawValue, placed: true))
            } catch let error as DaemonError {
                switch error {
                case .notConnected, .connectionClosed, .daemonShutdown: return .failure(.offline)
                case .command(_, let message, let code, _, _): return .failure(.refused(message.isEmpty ? code ?? "" : message))
                default: return .failure(.refused(error.description))
                }
            } catch {
                return .failure(.refused(String(describing: error)))
            }
        }
        do {
            let record = try await directory.createChief(named: name)
            if !record.placed { await hostedChief.enableBrain(of: record.id) }
            pendingSelection = record.mainConversation.map { ConversationID($0) }
            return .success(record)
        } catch FeedServiceError.signedOut {
            return .failure(.offline)
        } catch FeedServiceError.owner(let code, let message) {
            return .failure(.refused(code == "policy.denied" || code == "validation.invalid" ? message : code))
        } catch {
            return .failure(.refused(""))
        }
    }

    /// `chief.create` on the signed-in account's cloud Chiefs (the default engine).
    private func createCloudChief(named name: String) async -> HomeComposeOutcome {
        do {
            let record = try await directory.createChief(named: name)
            // A new Chief's brain starts off: turn it on, or it never answers.
            if !record.placed { await hostedChief.enableBrain(of: record.id) }
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

    /// Archives one of my cloud Chiefs; nil when it is gone from the list (the cloud archive may
    /// still wait, HomeChiefArchive), else why not.
    func archiveChief(_ id: String) async -> String? {
        if directory.chief(for: ParticipantID(id)) == nil { await directory.refreshChiefs() }
        switch await directory.archiveChief(id) {
        case .archived, .hiddenHere: return nil
        case .refused(let reason): return reason
        }
    }

    /// The Chief record behind a conversation row, when the row is a DM
    /// with one of my cloud Chiefs (the local Chief is never archived).
    func chief(of row: InboxRow) -> HomeChiefRecord? {
        guard row.kind == .chief, let me = homeStore.me?.id,
              let agent = row.summary.participants.first(where: { $0.id != me && $0.isChief }) else { return nil }
        return directory.chief(for: agent.id)
    }

    /// The one path for managing a DM or group: the group info sheet, the Home row menu and the
    /// `home.*` group actions (AppActions+HomeGroups) all run it.
    var groupActions: HomeGroupActions {
        HomeGroupActions(store: homeStore, muting: groupMuting, contacts: { [weak self] in self?.contacts() ?? [] })
    }

    /// The one path every "Send Message…" entry point resolves its chat through (right-click
    /// rows, Send to Chief, Forward…, `cmux chat send`, MCP): AppActions+HomeMessaging.
    var messageRouting: HomeMessageRouting {
        HomeMessageRouting(store: homeStore, actions: groupActions,
                           chief: { [weak self] in
            guard let self, let chief = TopHomePageView.chief(self) else { return nil }
            return ConversationID(chief)
        }, chiefNames: { [weak self] in self?.chiefNames ?? [:] })
    }

    /// The Home sidebar's data source (the vendored MessagesLab sidebar reads it):
    /// choosing a row shows its conversation on the Home page, a person starts a DM.
    func makeSidebarSource() -> HomeSidebarSource {
        // The list's first frame is the last launch's list (HomeService+LaunchList).
        primeHomeList()
        let store = homeStore
        let source = HomeSidebarSource(
            store: HomePinStore(), inboxes: [homeInbox, homeCloudInbox], account: { [weak self] in self?.pinAccount ?? "local" },
            rows: { [weak self] in HomeArchivedChiefs(self?.directory.archivedChiefs ?? [], me: store.me?.id).visible(store.rows) },
            me: { store.me?.id }, contacts: { [weak self] in self?.contacts() ?? [] },
            chiefAvatars: { [weak self] in self?.chiefFaces ?? [:] },
            defaultChiefAvatar: { .chiefDefault },  // never the default Chief's pick on another Chief's row
            chiefHarnesses: { [weak self] in self?.directory.chiefHarnesses ?? [:] },
            chiefRoster: { [weak self] in self?.chiefRoster ?? HomeChiefRoster() },
            chiefNames: { [weak self] in self?.chiefNames ?? [:] })
        source.onSelect = { [weak self] id in self?.pendingSelection = id }
        // The unread indicator outside Home reads `groupMuting`: a mark set in a page's own source reaches it.
        source.onMarksChanged = { [weak self] in self?.groupMuting.reloadMarks() }
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

    /// Reads each listed local Chief's own avatar for its tile (its picture in the daemon's
    /// Chief registry, which the profile and chiefs tools write, else its profile.json text;
    /// none: the chosen pet character), as each Chief's header does. A Chief's picture never shows on another's row.
    func refreshChiefAvatars() {
        let chiefs = Set(homeStore.rows.filter { !isCloudConversation($0.id) }
            .flatMap { $0.summary.participants.filter(\.isChief).map(\.id.rawValue) })
        let reader = HomeChiefAvatars(muxHome: HomeBrainHost.muxHome(tag: services.environment.tag),
                                      registry: DaemonChiefAvatarRegistry(connection: connection))
        // task-owner: one read of a few small files off the main actor; ends when it is set
        Task { [weak self] in
            let avatars = await reader.read(chiefs: chiefs)
            guard let self, directory.chiefAvatars != avatars else { return }
            directory.chiefAvatars = avatars
        }
    }

    /// The record name of the Chief whose conversation is `conversation` (issue 26393): a cloud
    /// Chief's `chief.list` entry, a Chief of this Mac its registry name from `home-inbox`; nil
    /// for a conversation that is no Chief's own (a group, a DM with a person) or a Chief with no name.
    func chiefRecord(of conversation: ConversationID) -> String? {
        if let cloud = directory.chiefs.first(where: { $0.mainConversation == conversation.rawValue }),
           let name = HomeChiefNames.trimmed(cloud.name) { return name }
        return HomeChiefNames.localRecord(of: conversation, in: homeInbox.rows)
    }

    /// Each Chief's one name by its conversation, for the list's tiles (``chiefName(of:)``).
    var chiefNames: [ConversationID: String] {
        var records = HomeChiefNames.localRecords(homeInbox.rows)
        for chief in directory.chiefs {
            guard let conversation = chief.mainConversation, let name = HomeChiefNames.trimmed(chief.name) else { continue }
            records[ConversationID(conversation)] = name
        }
        return chiefRenames.all(records)
    }

    /// The name `conversation`'s Chief shows everywhere: the list's tile, the chat header, the
    /// settings card, the tab strip, banners and Send Message… (its record's, or a rename being
    /// saved); nil when it is no Chief's, and the conversation's title shows.
    func chiefName(of conversation: ConversationID) -> String? {
        chiefRenames.name(of: conversation, record: chiefRecord(of: conversation))
    }

    /// Renames conversation `conversation` from its header card. A Chief's own conversation renames
    /// the Chief's record, and the new name shows on every surface at once while it is saved, then
    /// the record decides; a refused save shows the record's name again. A cloud Chief renames its
    /// account record (UserDO renames its conversation after); a Chief of this Mac its registry
    /// record, whose owner retitles the Chief's own conversation. Any other conversation with a
    /// Chief (a group, a channel) is renamed itself. Nil when saved, else why not.
    func renameChief(conversation: String, to name: String) async -> HomeChiefRenameFailure? {
        let id = ConversationID(conversation)
        if isCloudConversation(id) {
            return await renamingRecord(id, to: name) { await self.directory.renameChief(conversation: conversation, to: name) }
        }
        guard let connection else { return .noConnection }
        // The owner's row says whether this is a Chief's own conversation; before its first answer, the store's row.
        let row = homeInbox.rows?.first { $0.id == conversation }
        let isChiefs = row.map { $0.kind == "chief" } ?? (homeStore.rows.first { $0.id == id }?.kind == .chief)
        guard isChiefs, let chief = row?.chief ?? homeStore.summary(id).flatMap({ Self.soleChief(of: $0.participants) }) else {
            return await HomeConversationRename(conversation: conversation, name: name).send(over: connection)
        }
        return await renamingRecord(id, to: name) { await HomeLocalChiefRename(chief: chief, name: name).send(over: connection) }
    }

    /// Runs `save` with `name` shown for `id` meanwhile (only for a Chief with a record); a refusal
    /// rolls it back, a save that lands keeps it until the record leaves the names it replaced.
    private func renamingRecord(_ id: ConversationID, to name: String,
                                save: () async -> HomeChiefRenameFailure?) async -> HomeChiefRenameFailure? {
        guard chiefRecord(of: id) != nil else { return await save() }
        chiefRenames.rename(id, to: name, record: chiefRecord(of: id))
        let failure = await save()
        if failure != nil {
            chiefRenames.rollBack(id, name: name)
        } else {
            settleRename(id)
        }
        return failure
    }

    /// Drops `id`'s shown rename once its record moves past the names it replaced (the save's echo,
    /// or anyone's rename since); event-driven, it ends then.
    private func settleRename(_ id: ConversationID) {
        // task-owner: one saved rename; Observation of the Chief's record, ends when the rename is settled
        // (or with the service, if the save's echo never comes: the rename then keeps showing, as saved)
        Task { [weak self] in
            for await record in ObservationStream({ self?.chiefRecord(of: id) }) {
                guard let self else { return }
                // No record read (the list reconnecting) settles nothing: the saved name keeps showing.
                guard record != nil else { continue }
                chiefRenames.settle(id, record: record)
                if !chiefRenames.isPending(id) { return }
            }
        }
    }

    /// Each listed Chief's avatar as its Home row, header and bubbles draw it: its own picture or
    /// text, else its own upload or picked character (`AppServices.chosenPicture(of:)`), so one Chief's
    /// never shows on another; a Chief with none is left out and draws its name's monogram.
    var chiefFaces: [String: HomeChiefAvatar] {
        var chiefs = Set(homeStore.rows.flatMap { $0.summary.participants.filter(\.isChief).map(\.id.rawValue) } + [HomeChiefAvatars.defaultChief])
        #if DEBUG
        chiefs.formUnion(debugChiefs)
        #endif
        return Self.chiefFaces(chiefs: chiefs, own: directory.chiefAvatars) { services.chosenPicture(of: $0) }
    }

    /// Chief `chief` (a participant id) as an agent chat draws a message it sent there
    /// (`chief.face`, manaflow-ai/cmux#27914): the name and avatar Home and the sidebar show for it.
    func agentPageFace(of chief: String, avatars: AgentAvatars) async -> [String: String] {
        // The one name its tile, header and tab show (a rename being saved included): its own
        // conversation's; else what a conversation or its record calls it.
        let own = homeStore.rows.first { Self.soleChief(of: $0.summary.participants) == chief }
        let name = own.flatMap { chiefName(of: $0.summary.id) }
            ?? homeStore.rows.lazy.flatMap(\.summary.participants).first { $0.id.rawValue == chief }?.displayName
            ?? directory.chiefs.first { $0.id == chief }?.name
        // The sidebar draws the default Chief (`agent_mux`) with no id.
        var picture = services.chosenPicture(of: chief == DaemonHomeSource.chief.id ? nil : chief), text: String?
        switch chiefFaces[chief] {
        case .picture(let url): picture = url
        case .text(let own): text = own
        case nil: break
        }
        if picture == nil, text == nil { text = HomeChiefAvatar.monogram(of: name ?? "") }  // as Home's header (C)
        return await avatars.chiefFace(name: name, picture: picture, text: text)
    }

    /// `own` (each Chief's own avatar), with each other Chief in `chiefs` wearing its `picture` (its upload) when it has one.
    static func chiefFaces(chiefs: Set<String>, own: [String: HomeChiefAvatar], picture: (String) -> URL?) -> [String: HomeChiefAvatar] {
        var faces = own.compactMapValues(\.chosen)
        for chief in chiefs where faces[chief] == nil {
            if let url = picture(chief) { faces[chief] = .picture(url) }
        }
        return faces
    }

    /// The participant id of the one Chief in `participants`; nil for none or several.
    static func soleChief(of participants: [Participant]) -> String? {
        let chiefs = participants.filter(\.isChief)
        return chiefs.count == 1 ? chiefs[0].id.rawValue : nil
    }
}

enum HomeActionChiefResult {
    case success(HomeChiefRecord)
    case failure(HomeComposeOutcome)
}
