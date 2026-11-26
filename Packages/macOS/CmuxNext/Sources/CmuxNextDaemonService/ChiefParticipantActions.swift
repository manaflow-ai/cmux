public import AppKit
public import CmuxNextActions
public import CmuxNextDaemon
import CmuxNextCompat
public import UniformTypeIdentifiers

/// The person's own picture and an agent made a Chief: `participant.avatar.set` and
/// `chief.profile.adopt` on the app's own connection to this Mac's Chief owner, which alone may run
/// them (the palette rows of `cmux avatar set` and `cmux chief adopt`).
@MainActor
public struct ChiefParticipantActions {
    public init() {}
    /// The picture types the owner takes.
    public static let pictureTypes: [UTType] = [.png, .jpeg, .gif, .webP]
    /// The owner's limit on a picture's size.
    public nonisolated static let pictureMaxBytes = 1 << 20

    /// Binds Set My Picture… (`home.setMyAvatar`): asks for an image, then sets it as the person's
    /// own conversation picture (`user_local`).
    ///
    /// - Parameters:
    ///   - connection: The app's connection to the Chief owner; nil before Home is ready.
    ///   - window: The window the file panel attaches to; nil shows it on its own.
    public static func bindSetMyPicture(into registry: ActionRegistry, connection: @escaping @MainActor () -> DaemonConnection?,
                                        window: @escaping @MainActor () -> NSWindow?) {
        registry.bindEffect("home.setMyAvatar", effect: { _ in
            guard let connection = connection() else { return .refused(RefusalStrings.homeNotReady) }
            let panel = NSOpenPanel()
            panel.allowedContentTypes = pictureTypes
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            let use: (NSApplication.ModalResponse) -> Void = { response in
                guard response == .OK, let url = panel.url else { return }
                registry.trackOrRefuse(ActionWork { await setMyPicture(url, connection: connection) })
            }
            if let window = window() { panel.beginSheetModal(for: window, completionHandler: use) } else { panel.begin(completionHandler: use) }
            return .done
        })
    }

    /// Uploads the picture at `url` as the person's own; nil when set, else why not.
    static func setMyPicture(_ url: URL, connection: DaemonConnection) async -> ActionWorkFailure? {
        do {
            // task-owner: the action's work awaits it; one bounded file read off the main actor.
            guard let bytes = try await Task.detached(priority: .userInitiated, operation: { try pictureBytes(url) }).value else {
                return ActionWorkFailure(refusal: .unavailable, reason: RefusalStrings.pictureTooLarge)
            }
            let params: [String: JSONValue] = ["participant_id": .string("user_local"), "bytes": .string(bytes.base64EncodedString()),
                                               "machine": .string("current"), "session": .string("current")]
            _ = try await ResourceRelayClient(connection: connection).send(
                operation: "participant.avatar.set", params: params, idempotencyKey: "home-my-picture-\(UUID().uuidString.lowercased())")
            return nil
        } catch {
            return ActionWorkFailure("participant.avatar.set", error)
        }
    }

    /// The bytes of the picture at `url`, or nil when it is over ``pictureMaxBytes``.
    nonisolated static func pictureBytes(_ url: URL) throws -> Data? {
        let size = try url.blockingResourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        return size > pictureMaxBytes ? nil : try Data(blockingContentsOf: url)
    }

    /// Make This Agent a Chief (`agentPane.adoptAsChief`): the agent participant the acpmux session
    /// `session` runs becomes a Chief under its own participant id; its conversations and history stay.
    /// An agent in no local conversation yet is refused with why.
    public static func adoptAsChief(session: String, connection: DaemonConnection) -> ActionEffect {
        // action-wait-allow: the Chief owner, another process, decides whether the agent can be adopted; nothing local stands in for a Chief
        .waiting(.externalProcess) {
            do {
                let participants = try await ConversationClient(connection).list().flatMap(\.participants)
                guard let agent = participants.first(where: { $0.kind == .agent && $0.acpSession == session && $0.leftAt == nil }) else {
                    return ActionWorkFailure(refusal: .unavailable, reason: RefusalStrings.agentNotInConversation)
                }
                let params: [String: JSONValue] = ["participant_id": .string(agent.id), "machine": .string("current"), "session": .string("current")]
                _ = try await ResourceRelayClient(connection: connection).send(
                    operation: "chief.profile.adopt", params: params, idempotencyKey: "agent-adopt-chief-\(UUID().uuidString.lowercased())")
                return nil
            } catch {
                return ActionWorkFailure("chief.profile.adopt", error)
            }
        }
    }
}
