public import CmuxNextActions
public import CmuxNextAgentActivity
public import CmuxNextAgentPane
import CmuxNextBridge
public import CmuxNextDesignTokens
public import CmuxNextFloating
public import CmuxNextSettings
public import Foundation

/// The chat the Chief pet (the floating mini) stands for (``ChiefPetSubject``, Show in Mini; Leo
/// 2026-11-07: "we point it not necessarily at the chief, but at a particular coordinator chat"):
/// what it wears, what it draws and what its reply box shows, read under the pet's observation
/// (each read is one keyed record of the lane and turn stores, so another chat's change wakes
/// nothing), and Show in Mini itself (the palette's `agentPane.showInMini`, the chat menu's
/// `agent.mini.show`). With no chat picked, the Chief. The App passes what only it has.
@MainActor
public final class ChiefPetMini {
    public static let action: ActionID = "agentPane.showInMini"

    public let subject: ChiefPetSubject
    private let uploads: ChiefAvatarUploads
    private let lanes: AgentLaneStore
    /// `install:<id>` of this Mac: a chat of its own acpmux is kept under it.
    private let localHost: @MainActor () -> String?
    private let settings: @MainActor () -> SettingsController?
    private let pet: @MainActor () -> ChiefPetController?
    /// The acpmux this app runs (resolved once at startup), and the sender of the reply box's messages.
    private let acpmux: AcpmuxEnvironment?
    private let replies = AcpmuxReplySender()

    public init(subject: ChiefPetSubject = ChiefPetSubject(), uploads: ChiefAvatarUploads, lanes: AgentLaneStore = .shared,
                localHost: @escaping @MainActor () -> String?, settings: @escaping @MainActor () -> SettingsController?,
                pet: @escaping @MainActor () -> ChiefPetController?, acpmux: AcpmuxEnvironment?) {
        self.subject = subject
        self.uploads = uploads
        self.lanes = lanes
        self.localHost = localHost
        self.settings = settings
        self.pet = pet
        self.acpmux = acpmux
    }

    /// The upload the mini wears: the chat's own avatar (Set Chat Avatar…); for the Chief, `chief`
    /// (its worn upload). None: the character.
    public func upload(chief: () -> URL?) -> URL? {
        guard let chat = subject.chat else { return chief() }
        return uploads.uploads[ChiefAvatarUploads.key(agent: chat.session)]?.file
    }

    /// The mini's chat's turn as acpmux decided its lane (this Mac's chat or a peer's); for the
    /// Chief, its sidebar status `chief`.
    public func state(chief: () -> StatusIndicatorState) -> ChiefPetState {
        guard let chat = subject.chat else { return Self.state(chief()) }
        return Self.state(lanes.lane(chat.session)?.state)
    }

    /// The Chief's sidebar status as the pet draws it: working, waiting on you, failed, else idle.
    public nonisolated static func state(_ activity: StatusIndicatorState) -> ChiefPetState {
        switch activity {
        case .working, .busy: .working
        case .waiting: .waiting
        case .error: .error
        case .idle, .paused, .success: .idle
        }
    }

    /// A chat's lane as the pet draws it; no lane yet is idle, never working.
    public nonisolated static func state(_ lane: AgentActivityLane.State?) -> ChiefPetState {
        switch lane {
        case .working: .working
        case .input: .waiting
        case .failed, .lost: .error
        case .idle, nil: .idle
        }
    }

    /// The mini's chat, its title (acpmux's) and its newest reply (acpmux's last message that is not
    /// the person's).
    public func home() -> ChiefPetHome {
        guard let chat = subject.chat else { return .chief }
        let title = lanes.lane(chat.session)?.title ?? chat.session
        return ChiefPetHome(chat: chat, title: title, latest: AgentTurnStateStore.shared.lastMessage(session: chat.session))
    }

    /// The key `acpmux send` takes for `chat`: its stable id (a peer's chat is the session this
    /// Mac's acpmux mirrors), else `HOST/ID` with the host saved when it was picked.
    func sendName(_ chat: ChiefPetSubject.Chat) -> String {
        guard chat.host != localHost(), !chat.session.contains("/") else { return chat.session }
        return chat.host + "/" + chat.session
    }

    /// The reply box's message to `chat`, as the person's own `acpmux send` (queued behind a running
    /// turn, off the main thread). One id per message: acpmux delivers a repeat of it once.
    public func send(_ text: String, to chat: ChiefPetSubject.Chat) async -> Bool {
        await replies.send(session: sendName(chat), text: text, promptID: UUID().uuidString.lowercased(), environment: acpmux)
    }

    /// Opens `chat`'s agent chat tab (`agent.openSessionTab`; no `host` for this Mac's own).
    public func open(_ chat: ChiefPetSubject.Chat, registry: ActionRegistry) {
        var arguments: [String: ActionValue] = ["session": .string(chat.session)]
        if chat.host != localHost() { arguments["host"] = .string(chat.host) }
        _ = registry.perform("agent.openSessionTab", invocation: ActionInvocation(arguments: arguments, origin: .user))
    }

    /// The chat `model` shows as the mini can stand for it: a chat of this Mac's acpmux, a peer's as
    /// the session it mirrors here. None for a Chief home's or another machine's tab
    /// (`miniUnreachable`): the mini reads state and sends through this Mac's acpmux.
    public func chat(of model: AgentPaneModel) -> ChiefPetSubject.Chat? {
        guard !model.miniUnreachable, let session = model.sessionId, let host = localHost() else { return nil }
        return ChiefPetSubject.Chat(host: host, session: session)
    }

    /// The chat menu's Show in Mini on `model`'s page: its chat (`session` set), or the Chief again.
    public func show(session: String?, of model: AgentPaneModel, registry: ActionRegistry) {
        if session == nil { show(nil, registry: registry) } else if let chat = chat(of: model) { show(chat, registry: registry) }
    }

    /// Show in Mini for `chat` (nil: the Chief again). Asking to see a chat in the mini
    /// shows the mini: off, it turns on (`home.toggleChiefPet` with `on`, the person's own run); a
    /// managed setting that keeps it off shows it for this chat with its reply box open, as Message
    /// the Chief does.
    public func show(_ chat: ChiefPetSubject.Chat?, registry: ActionRegistry) {
        subject.show(chat)
        guard chat != nil, settings()?.snapshot.homeChiefPetEnabled == false else { return }
        if registry.canPerform(HomeChiefPetSetting.toggleAction) {
            _ = registry.perform(HomeChiefPetSetting.toggleAction, invocation: ActionInvocation(arguments: ["on": .bool(true)], origin: .user))
        } else {
            pet()?.summon(petOn: false)
        }
    }

    /// Show in Mini in the palette, on the focused chat page `focused` names: run while the mini shows it already, it reads Show Chief in Mini and gives the mini
    /// back to the Chief.
    public func bind(into registry: ActionRegistry, focused: @escaping @MainActor (ActionInvocation) -> AgentPaneModel?) {
        registry.bindEffect(Self.action) { [weak self, weak registry] invocation in
            guard let self, let registry, let chat = focused(invocation).flatMap(chat(of:)) else {
                return .refused(ChiefPetSubject.needsAgentChatTitle)
            }
            show(subject.chat == chat ? nil : chat, registry: registry)
            return .done
        }
        ActionTargetTitles.setPaletteTitle(Self.action, in: registry) { [weak self] in
            guard let self, let chat = focused(ActionInvocation()).flatMap(chat(of:)), subject.chat == chat else { return nil }
            return ChiefPetSubject.showChiefTitle
        }
    }
}
