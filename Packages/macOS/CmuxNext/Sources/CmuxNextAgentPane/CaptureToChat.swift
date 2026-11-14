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
/// `chat.capture.toChat {"region": [x, y, w, h]}` runs the same path with that region and no pick, for
/// scripted walks (the screenshot-into-chat probe), and answers `{session, path, bytes}`.
public struct CaptureToChat: Sendable {
    public static let action: ActionID = "palette.captureScreenshotToChat"
    public static let method = "chat.capture.toChat"

    /// Takes the picture (``ScreenshotToChat/take(_:taken:)``).
    let take: @MainActor @Sendable (ScreenshotToChat.Pick) async -> ScreenshotToChat.Outcome
    /// The route into a chat and the app it names.
    let attach: @MainActor @Sendable ([URL], String?) -> Void
    /// The session of the chat that took the picture, when known (``AgentPaneExternalAttach/lastSession``).
    let session: @MainActor @Sendable () -> String?
    /// The app the picture comes from: cmux took it, so its chip wears cmux's icon, as + > Attach
    /// Screenshot…'s does.
    let source: String?

    init(take: @escaping @MainActor @Sendable (ScreenshotToChat.Pick) async -> ScreenshotToChat.Outcome,
         attach: @escaping @MainActor @Sendable ([URL], String?) -> Void,
         session: @escaping @MainActor @Sendable () -> String?, source: String?) {
        self.take = take
        self.attach = attach
        self.session = session
        self.source = source
    }

    /// The app's: the picture kept under Chat Uploads, handed to `attach` (the App's route into a
    /// chat) as cmux's own, and `route`'s last chat for the answer's session.
    public init(route: AgentPaneExternalAttach, attach: @escaping @MainActor @Sendable ([URL], String?) -> Void) {
        self.init(take: { pick in
            guard let folders = ChatUploadFolders.standard else { return .failed("no Application Support folder") }
            return await ScreenshotToChat(folders: folders).take(pick)
        }, attach: attach, session: { [weak route] in
            route?.lastSession
        }, source: Bundle.main.bundleIdentifier)
    }

    /// Takes `pick` and, when a picture was taken, hands it to the route.
    @MainActor func run(_ pick: ScreenshotToChat.Pick) async -> ScreenshotToChat.Outcome {
        let outcome = await take(pick)
        if case .taken(let file, _) = outcome { attach([file], source) }
        return outcome
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

    /// `chat.capture.toChat`: `{"region": [x, y, w, h]}` (global points from the top-left) takes that
    /// region with no pick; without one it runs the pick. Answers `{session, path, bytes}`, or
    /// `{cancelled: true}` for an Esc; a capture that fails is the `capture_failed` error.
    public func controlMethod() -> ControlMethod {
        let capture = self
        return ControlMethod.async(Self.method) { call in
            let pick: ScreenshotToChat.Pick
            do {
                pick = try ScreenshotToChat.pick(from: call.params)
            } catch let bad as ScreenshotToChat.BadRegion {
                throw ControlError.invalidParams(bad.message)
            }
            switch await capture.run(pick) {
            case .taken(let file, let bytes):
                return await ScreenshotToChat.answer(session: capture.session(), file: file, bytes: bytes)
            case .cancelled:
                return ScreenshotToChat.cancelledAnswer
            case .failed(let reason):
                throw ControlError(code: "capture_failed", message: reason)
            }
        }.withDeadline(.fixed(.seconds(120)))
    }
}
