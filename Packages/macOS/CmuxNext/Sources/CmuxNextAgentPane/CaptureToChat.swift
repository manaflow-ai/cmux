public import CmuxNextActions
public import CmuxNextControl
import CmuxNextSettings
public import Foundation

/// Capture Screenshot to Chat (`palette.captureScreenshotToChat`), one of the doors from another app
/// into a chat (Leo, 2026-11-08, ask-a862e90c70: a person sends a screenshot into a cmux NEXT chat
/// straight from another app in one step). Its key, the palette and, while
/// `app.captureScreenshotGlobalHotKey` is on, the same key with another app in front run the system's
/// region pick; the still goes through the one route into a chat's composer (the App's
/// `ExternalOpenController.attachToChat`, ``AgentPaneExternalAttach``): the focused agent chat, else a
/// new chat, as an unsent draft, with cmux brought forward and the composer focused. Esc takes nothing
/// and does nothing.
///
/// `chat.capture.toChat` runs the same path, the system's pick included, and answers `{session, path,
/// bytes}`. A region with no pick is refused there: it would let any caller of the control socket read
/// other apps' windows with cmux's Screen Recording grant (cmux#43102 review F1; the scripted form waits
/// on cmux#13742).
public struct CaptureToChat: Sendable {
    public static let action: ActionID = "palette.captureScreenshotToChat"
    public static let method = "chat.capture.toChat"

    /// Takes the picture (``ScreenshotToChat/take(_:taken:)``).
    let take: @MainActor @Sendable (ScreenshotToChat.Pick) async -> ScreenshotToChat.Outcome
    /// The route into a chat and the app it names.
    let attach: @MainActor @Sendable ([URL], String?) -> Void
    /// The session of the chat that synchronously took this picture, when known.
    let session: @MainActor @Sendable (URL) -> String?
    /// The app the picture comes from: cmux took it, so its chip wears cmux's icon, as + > Attach
    /// Screenshot…'s does.
    let source: String?

    init(take: @escaping @MainActor @Sendable (ScreenshotToChat.Pick) async -> ScreenshotToChat.Outcome,
         attach: @escaping @MainActor @Sendable ([URL], String?) -> Void,
         session: @escaping @MainActor @Sendable (URL) -> String?, source: String?) {
        self.take = take
        self.attach = attach
        self.session = session
        self.source = source
    }

    /// The app's: the picture kept under Chat Uploads, handed to `attach` (the App's route into a
    /// chat) as cmux's own. The answer identifies the chat that received that file, when known.
    public init(route: AgentPaneExternalAttach, attach: @escaping @MainActor @Sendable ([URL], String?) -> Void) {
        self.init(take: { pick in
            guard let folders = ChatUploadFolders.standard else { return .failed("no Application Support folder") }
            return await ScreenshotToChat(folders: folders).take(pick)
        }, attach: attach, session: { [weak route] file in
            route?.session(for: file)
        }, source: Bundle.main.bundleIdentifier)
    }

    /// Takes `pick` and, when a picture was taken, hands it to the route.
    @MainActor func run(_ pick: ScreenshotToChat.Pick) async -> ScreenshotToChat.Outcome {
        let (outcome, _) = await runAndReport(pick)
        return outcome
    }

    /// Takes, routes and records the destination in one main-actor turn. The session lookup follows
    /// `attach` synchronously, before this method's caller can interleave another route operation.
    @MainActor private func runAndReport(_ pick: ScreenshotToChat.Pick) async -> (ScreenshotToChat.Outcome, String?) {
        let outcome = await take(pick)
        guard case .taken(let file, _) = outcome else { return (outcome, nil) }
        attach([file], source)
        return (outcome, session(file))
    }

    /// The action: the pick shows at once (macOS's own), and the attach follows it. A pick that could
    /// not start (no Screen Recording grant) says so; Esc says nothing.
    @MainActor public func bind(into registry: ActionRegistry) {
        let capture = self
        registry.bindEffect(Self.action, effect: { _ in
            .applied(ActionConfirmation(send: {
                if case .failed = await capture.run(.picker) { return ActionWorkFailure(ScreenshotToChat.failedMessage) }
                return nil
            }))
        })
    }

    /// `chat.capture.toChat`: runs the system's pick, where the person chooses what to take. Answers
    /// `{session, path, bytes}`, or `{cancelled: true}` for an Esc; a capture that fails is the
    /// `capture_failed` error. A `region` is refused as person-only: a picture with no pick would hand
    /// the caller whatever is on screen, past the person and past the browser's capture mask.
    public func controlMethod() -> ControlMethod {
        let capture = self
        return ControlMethod.async(Self.method) { call in
            try await capture.respond(to: call.params)
        }.withDeadline(.fixed(.seconds(120)))
    }

    /// The method's answer for `params`; a region is refused before anything is taken.
    func respond(to params: [String: JSONValue]) async throws -> JSONValue {
        if let region = params["region"], region != .null { throw ControlError.personOnly() }
        let (outcome, destination) = await runAndReport(.picker)
        switch outcome {
        case .taken(let file, let bytes):
            return ScreenshotToChat.answer(session: destination, file: file, bytes: bytes)
        case .cancelled:
            return ScreenshotToChat.cancelledAnswer
        case .failed(let reason):
            throw ControlError(code: "capture_failed", message: reason)
        }
    }
}
