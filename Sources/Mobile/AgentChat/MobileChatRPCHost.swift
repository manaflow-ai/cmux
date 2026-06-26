import CmuxAgentChat
import CmuxTerminal
import Foundation

/// The host seam ``MobileChatRPCHandler`` reaches back through to drive the
/// app-target terminal data plane it does not own.
///
/// The `mobile.chat.*` handlers reuse the existing mobile terminal injection
/// machinery (`mobile.terminal.paste` / `paste_image`) and the shared
/// workspace/surface resolver so chat input behaves exactly like composer
/// input. Those operations live on ``TerminalController`` (the data-plane god
/// object being drained); this protocol exposes only the narrow set the chat
/// handler needs, so the chat dispatch logic can live in its own owner instead
/// of as an extension on the god object. ``TerminalController`` conforms with
/// one-line forwards to its existing bodies, so the wire behavior is identical.
@MainActor
protocol MobileChatRPCHost: AnyObject {
    /// The Mac-side chat transcript registry, or `nil` when the chat service is
    /// not wired into this process (then chat RPCs fail with an actionable
    /// "service unavailable" error).
    var mobileChatTranscriptService: AgentChatTranscriptService? { get }

    /// Resolves a workspace and (optionally) its target terminal surface from
    /// RPC params, materializing a lazily-created surface when `requireTerminal`
    /// is set. Returns `nil` when the params do not resolve.
    func mobileChatResolveWorkspaceAndSurface(
        params: [String: Any],
        requireTerminal: Bool
    ) -> (workspace: Workspace, surfaceId: UUID?)?

    /// Pastes text into the resolved session's terminal (bracketed paste +
    /// submit), reusing the shared `mobile.terminal.paste` body.
    func mobileChatPasteText(params: [String: Any]) -> TerminalController.V2CallResult

    /// Pastes a decoded image attachment into the resolved session's terminal,
    /// reusing the shared `mobile.terminal.paste_image` body.
    func mobileChatPasteImage(params: [String: Any]) -> TerminalController.V2CallResult

    /// String param accessor (trimmed, empty-as-absent) matching the v2 wire
    /// coercion the other mobile handlers use.
    func mobileChatStringParam(_ params: [String: Any], _ key: String) -> String?

    /// Raw string param accessor (untrimmed) matching the v2 wire coercion.
    func mobileChatRawStringParam(_ params: [String: Any], _ key: String) -> String?

    /// Integer param accessor matching the v2 wire coercion (NSNumber-clamped,
    /// boolean-coerced) the other mobile handlers use.
    func mobileChatIntParam(_ params: [String: Any], _ key: String) -> Int?

    /// Localized "the input queue is full" terminal error message.
    var mobileChatInputQueueFullMessage: String { get }

    /// Localized "the terminal surface is unavailable" error message.
    var mobileChatSurfaceUnavailableMessage: String { get }

    /// Localized "the agent process exited" terminal error message.
    var mobileChatProcessExitedMessage: String { get }
}
