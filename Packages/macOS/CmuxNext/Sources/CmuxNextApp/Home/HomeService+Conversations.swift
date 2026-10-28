import CmuxHomeCore
import CmuxNextDaemon
import CmuxNextChiefPetWiring
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
        let rows = TopHomePageView.visible(homeStore.rows, archivedChiefs: directory.archivedChiefs, me: me)
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
                         fallback: HomeHostView.defaultTileAvatar(mascot: services?.settings?.snapshot.homeChiefPetMascot),
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
        })
    }

    /// The Home sidebar's data source (the vendored MessagesLab sidebar reads it):
    /// choosing a row shows its conversation on the Home page, a person starts a DM.
    func makeSidebarSource() -> HomeSidebarSource {
        // The list's first frame is the last launch's list (HomeService+LaunchList).
        primeHomeList()
        let store = homeStore
        let source = HomeSidebarSource(
            store: HomePinStore(), inboxes: [homeInbox, homeCloudInbox], account: { [weak self] in self?.pinAccount ?? "local" },
            rows: { [weak self] in TopHomePageView.visible(store.rows, archivedChiefs: self?.directory.archivedChiefs ?? [], me: store.me?.id) },
            me: { store.me?.id }, contacts: { [weak self] in self?.contacts() ?? [] },
            chiefAvatars: { [weak self] in self?.chiefFaces ?? [:] },
            defaultChiefAvatar: { [weak self] in HomeHostView.defaultTileAvatar(mascot: self?.services?.settings?.snapshot.homeChiefPetMascot) },
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
        guard let services else { return "local" }
        let auth = services.cloudAuth
        return auth.user.map { CloudIdentity.workerUserID(stackProjectID: auth.configuration.stackProjectID, stackUserID: $0.id) } ?? "local"
    }

    /// Reads each listed local Chief's own avatar for its tile (its picture in the daemon's
    /// Chief registry, which the profile and chiefs tools write, else its profile.json text;
    /// none: the chosen pet character), as each Chief's header does. A Chief's picture never shows on another's row.
    func refreshChiefAvatars() {
        guard let services else { return }
        let chiefs = Set(homeStore.rows.filter { !isCloudConversation($0.id) }
            .flatMap { $0.summary.participants.filter(\.isChief).map(\.id.rawValue) })
        let reader = HomeChiefAvatars(muxHome: HomeBrainHost.muxHome(tag: services.environment.tag),
                                      registry: DaemonChiefAvatarRegistry(connection: connection), files: services.work)
        // task-owner: one read of a few small files off the main actor; ends when it is set
        Task { [weak self] in
            let avatars = await reader.read(chiefs: chiefs)
            guard let self, directory.chiefAvatars != avatars else { return }
            directory.chiefAvatars = avatars
        }
    }

    /// Each cloud Chief's own name by its main conversation (`chief.list`, kept current by a rename),
    /// for the list's tiles; a Chief with no name set is left out and reads "Chief".
    var chiefNames: [ConversationID: String] {
        Dictionary(directory.chiefs.compactMap { chief in
            chief.mainConversation.flatMap { conversation in
                chief.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : (ConversationID(conversation), chief.name)
            }
        }, uniquingKeysWith: { first, _ in first })
    }

    /// Each listed Chief's avatar as its Home row, header and bubbles draw it: its own picture or
    /// text, else the picture of its own pet character (``ChiefMascotPicks``), so a character picked
    /// for one Chief never shows on another.
    var chiefFaces: [String: HomeChiefAvatar] {
        guard let services else { return [:] }
        let picks = services.chiefMascotPicks, snapshot = services.settings?.snapshot
        var chiefs = Set(homeStore.rows.flatMap { $0.summary.participants.filter(\.isChief).map(\.id.rawValue) })
        #if DEBUG
        chiefs.formUnion(debugChiefs)
        #endif
        return Self.chiefFaces(chiefs: chiefs, own: directory.chiefAvatars) {
            ChiefPetSettingsRows.avatarURL(of: picks.mascot(of: $0, in: snapshot))
        }
    }

    /// `own` (each Chief's own avatar), with each other Chief in `chiefs` wearing the `picture` of its character.
    static func chiefFaces(chiefs: Set<String>, own: [String: HomeChiefAvatar], picture: (String) -> URL?) -> [String: HomeChiefAvatar] {
        var faces = own
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
