public import CmuxHomeCore
public import CmuxNextActions
import CmuxNextCloud
public import CmuxNextHomeModel

/// New Channel (plans/cmux-next/chief-channels-DESIGN.md): `home.createChannel`, one path for the palette,
/// `cmux chat channel create` and MCP. `members` is a To: list ("Leo, ana@example.com"): a name resolves to a
/// teammate or connection and is added, an email is invited. The channel Chief's brain is turned on (a new
/// Chief's starts off), and a person's run shows the channel. The caller gets the channel, its Chief and one
/// line per invited person.
@MainActor
public struct HomeChannelActions {
    private let directory: HomeDirectory
    private let contact: @MainActor (String) -> ParticipantID?
    private let enableBrain: @MainActor (String) async -> Void
    private let show: @MainActor (ConversationID) -> Void

    /// - Parameters:
    ///   - directory: The account's Worker calls (`channel.create`, the invites).
    ///   - contact: A name or id to the person it names (``HomeGroupActions/contact(_:)``), nil when none.
    ///   - enableBrain: Turns a cloud Chief's brain on, by agent id.
    ///   - show: Shows a conversation on the Home page (a person's run).
    public init(directory: HomeDirectory, contact: @escaping @MainActor (String) -> ParticipantID?,
                enableBrain: @escaping @MainActor (String) async -> Void, show: @escaping @MainActor (ConversationID) -> Void) {
        (self.directory, self.contact, self.enableBrain, self.show) = (directory, contact, enableBrain, show)
    }

    /// Binds `home.createChannel` in `registry`.
    public func bind(into registry: ActionRegistry) {
        let actions = self
        registry.bindEffect("home.createChannel", effect: { invocation in
            let (title, members, chief) = (invocation["title"]?.stringValue ?? "", invocation["members"]?.stringValue ?? "", invocation["chief"]?.stringValue)
            let shows = invocation.origin == .user
            // task-owner: the action run (its `.waiting` work awaits it; a capturing caller gets its value).
            // main-hop-allow: the action's own `.waiting(.network)` work: it awaits the Worker's channel.create and does one show on success; no model change to batch
            let task: ActionResultWork = Task { @MainActor in
                do {
                    let made = try await actions.create(title: title, chiefName: chief, members: members)
                    if shows { actions.show(ConversationID(made.conversation)) }
                    return .success(Self.result(made))
                } catch {
                    return .failure(ActionWorkFailure(refusal: .unavailable, reason: Self.reason(error)))
                }
            }
            registry.track(result: task)
            // action-wait-allow: the Worker names the channel and its Chief (channel.create); no local stand-in has an id to show
            return .waiting(.network) {
                guard case .failure(let failure) = await task.value else { return nil }
                return failure
            }
        })
    }

    /// Resolves `members`, makes the channel and turns its Chief's brain on.
    public func create(title: String, chiefName: String?, members: String) async throws -> HomeChannelCreation {
        var people: [HomeChannelPerson] = []
        for name in HomeGroupActions.names(in: members) {
            if let id = contact(name) {
                people.append(.account(id.rawValue))
            } else if let address = ContactAddress.parse(name), address.isEmail {
                people.append(.email(name))
            } else {
                throw HomeChannelRefusal.unknownPerson(name)
            }
        }
        let made = try await directory.createChannel(title: title, chiefName: chiefName, people: people)
        await enableBrain(made.chief.id)
        return made
    }

    /// The run's answer: the channel, its Chief and one line per invited person.
    static func result(_ made: HomeChannelCreation) -> [String: ActionResultValue] {
        let invited: [ActionResultValue] = made.invited.map { .object(["who": .string($0.who), "ok": .bool($0.ok), "code": .string($0.code ?? "")]) }
        return ["conversation": .string(made.conversation), "chief": .string(made.chief.id), "chief_name": .string(made.chief.name), "invited": .array(invited)]
    }

    /// The refusal a person reads.
    static func reason(_ error: any Error) -> String {
        switch error {
        case HomeChannelRefusal.unknownPerson(let name): HomeGroupOutcome.unknownPerson(name).message ?? name
        case FeedServiceError.owner(_, let message): message
        default: HomeGroupOutcome.offline.message ?? ""
        }
    }
}
