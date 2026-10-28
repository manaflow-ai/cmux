import CmuxAgentQuestion
import CmuxMobileArtifacts
import Foundation

/// What a session looks like in lists and the toolbar (acpmux `SessionSummary` subset).
public struct AgentSessionSummary: Hashable, Sendable, Identifiable {
    public enum Status: String, Hashable, Sendable { case idle, ready, running, waiting, disconnected, closed }

    public var id: String
    public var name: String
    public var harness: String
    public var agentName: String
    public var cwd: String
    public var workspaceTitle: String
    public var macName: String
    public var branch: String?
    public var status: Status
    /// The tab's Mac (tab ids repeat across Macs); empty when not known.
    public var macID: String

    public init(
        id: String, name: String, harness: String, agentName: String, cwd: String, workspaceTitle: String,
        macName: String, branch: String? = nil, status: Status = .idle, macID: String = ""
    ) {
        self.id = id
        self.macID = macID
        self.name = name
        self.harness = harness
        self.agentName = agentName
        self.cwd = cwd
        self.workspaceTitle = workspaceTitle
        self.macName = macName
        self.branch = branch
        self.status = status
    }
}

/// One record from the session's event stream: an agent `session/update`, or an acpmux mux record.
public enum AgentSessionEvent: Hashable, Sendable {
    case update(ACPSessionUpdate)
    /// `user_message` (or the replayed prompt of a historical turn).
    case userMessage(text: String, promptId: String, turnId: String, attachments: [AgentAttachment], at: Date)
    case queued(text: String, promptId: String, position: Int)
    case dequeued(promptId: String)
    /// A waiting prompt's text changed (`queue_updated`, Edit queued prompt).
    case queueUpdated(promptId: String, text: String)
    /// The waiting prompts' order (`queue_order`, Move up / Move down).
    case queueOrder([String])
    case turnStarted(turnId: String, at: Date)
    case turnResult(turnId: String, status: AgentTurn.Status, errorText: String?, at: Date)
    /// The agent's request to its model failed and it is trying again (Claude Code's
    /// `system/api_retry`): the running turn says so instead of a bare "Working".
    case retrying(attempt: Int, maxAttempts: Int, status: Int?)
    /// `permission_request` / `_acpmux/permission_pending` that is a tool permission.
    case permissionRequest(ACPPermissionRequest)
    /// A permission request that maps to a question (AskUserQuestion, Codex user input).
    case question(AgentQuestion)
    /// `permission_decision`: the prompt was resolved (here or by another client).
    /// `answers`: a question's answers as the owner recorded them (harness-shaped).
    case permissionDecision(permissionId: String, optionId: String?, answers: AgentQuestionJSON? = nil)
    case questionAnswered(questionId: String, answer: AgentQuestionAnswer)
    /// The history a chat opened on leaves out older records (the attach's cap): its first
    /// turn is not where the session started.
    case earlierHistory(Bool)
    case modelsAvailable([ACPModelInfo], current: String?)
    case modesAvailable([ACPMode], current: String?)
    /// Whether this phone's Full-access setting on the Mac covers it (acpmux `initialize`
    /// `_meta.acpmux.fullAccess`, read on each connection; false after acpmux refuses it).
    case fullAccess(Bool)
    case status(AgentSessionSummary.Status)
    /// A call the source made for the person failed (refused allow, trust gate, link down).
    case clientError(String)
    /// A prompt that never reached the agent (an attachment upload failed, the
    /// link was down): the composer gets the draft back with the reason.
    /// `promptID` is the prompt's acpmux id: sent again with it, the Mac runs it at most once.
    case promptNotSent(text: String, attachments: [AgentAttachment], promptID: String, reason: String)
    /// `_meta.acpmux.subagents`: a subagent started or changed state.
    case subagent(AgentSubagentChange)
    /// An update from a subagent's own session (`_meta.acpmux.subagent`).
    case subagentUpdate(subagentID: String, ACPSessionUpdate)
    /// Several records applied as one change (a replayed history), so no
    /// half-replayed state (a past turn still "Working") is ever on screen.
    case batch([AgentSessionEvent])
}

/// A person's action in the chat, encoded by the source into acpmux calls:
/// `session/prompt`, `session/cancel`, `_acpmux/permission_respond`, `session/set_model`,
/// `session/set_mode`, `session/set_config_option`, `_acpmux/queue_remove`, `_acpmux/queue_edit`.
public enum AgentClientIntent: Hashable, Sendable {
    /// `promptID`: `_meta.acpmux.promptId`, which acpmux runs once; `resend`: the same prompt
    /// sent again after its reply was lost (acpmux also looks for the id in the session log).
    case prompt(text: String, attachments: [AgentAttachment], steer: Bool, promptID: String, resend: Bool)
    case cancel
    case respondPermission(permissionId: String, optionId: String?)
    case answerQuestion(questionId: String, answer: AgentQuestionAnswer)
    case setModel(String)
    case setMode(String)
    case setConfigOption(id: String, value: String)
    case removeQueued(promptId: String)
    /// Edit queued prompt: `_acpmux/queue_edit {op: update, text}`.
    case editQueued(promptId: String, text: String)
    /// Send now: `_acpmux/queue_edit {op: send_now}`.
    case sendQueuedNow(promptId: String)
    /// Move up / Move down: `_acpmux/queue_edit {op: move, index}` (0 is next).
    case moveQueued(promptId: String, index: Int)
}

public struct AgentAttachment: Hashable, Sendable, Identifiable {
    public enum Kind: Hashable, Sendable { case image, file }

    public var id: String
    public var kind: Kind
    public var name: String
    public var data: Data?

    public init(id: String = UUID().uuidString, kind: Kind, name: String, data: Data? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.data = data
    }

    /// The image MIME type from the data's signature (nil: not an image an
    /// agent accepts; the composer re-encodes others as JPEG).
    public var imageMIMEType: String? {
        guard kind == .image, let data, data.count >= 12 else { return nil }
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if bytes.starts(with: [0x47, 0x49, 0x46, 0x38]) { return "image/gif" }
        if bytes.starts(with: [0x52, 0x49, 0x46, 0x46]), bytes[8...11] == [0x57, 0x45, 0x42, 0x50] { return "image/webp" }
        return nil
    }

    /// The attachment as a preview reads it (composer and sent message alike).
    public var localFile: LocalFile { LocalFile(id: id, name: name, data: data, isImage: kind == .image) }

    /// The id prefix of an image a recorded prompt names (acpmux's `images[].id`, its bytes' hash).
    public static let recordedImagePrefix = "acpmux-image:"

    /// An image the Mac's record of a prompt names, without its bytes.
    /// `index`: its place in the prompt (the same image twice keeps two identities).
    public static func recordedImage(id: String, name: String?, index: Int = 0) -> AgentAttachment {
        AgentAttachment(id: recordedImagePrefix + id + (index > 0 ? "#\(index)" : ""), kind: .image, name: name ?? "Photo", data: nil)
    }

    /// acpmux's id of a recorded image (nil for one this phone holds), without the
    /// `#n` that keeps two copies of one image in a prompt apart.
    public var recordedImageID: String? {
        guard id.hasPrefix(Self.recordedImagePrefix) else { return nil }
        let rest = id.dropFirst(Self.recordedImagePrefix.count)
        return String(rest.split(separator: "#", maxSplits: 1).first ?? rest)
    }
}

/// The data side of an agent chat. The mock streams a scripted session offline;
/// the link-backed source (later) speaks acpmux over the `acpmux` link service.
@MainActor
public protocol AgentSessionSource: AnyObject {
    var summary: AgentSessionSummary { get }
    /// Every record from the start of the session (history replay), then live records.
    func events() -> AsyncStream<AgentSessionEvent>
    func send(_ intent: AgentClientIntent)

    // ACP parity (web UI acpmux/checkpoints and acpmux/handoff). Sources
    // without a feature throw `AgentFeatureUnavailable` with the reason.

    /// Whether `checkpoints()` and `restore(_:)` work for this session. The
    /// chat shows Checkpoints only when they do.
    var supportsCheckpoints: Bool { get }
    /// Repository checkpoints around this session's turns, newest first.
    func checkpoints() async throws -> [AgentCheckpoint]
    /// Restores the working tree to `checkpoint`; returns a one-line summary.
    func restore(_ checkpoint: AgentCheckpoint) async throws -> String
    /// Harnesses this session can continue in.
    func handoffTargets() async throws -> [AgentHandoffTarget]
    /// Prepares (or returns the existing) continuation to `target`.
    func prepareHandoff(to target: AgentHandoffTarget) async throws -> AgentHandoffDraft
    /// Sends the reviewed capsule and starts the target session.
    func startHandoff(_ draft: AgentHandoffDraft) async throws -> AgentHandoffReceipt
    func discardHandoff(_ draft: AgentHandoffDraft) async
    /// Loads the session's referenced files for the artifacts browser.
    var artifactSource: any ArtifactSource { get }
    /// The bytes of an attachment a recorded prompt names but this phone does not hold (an
    /// image another device or an earlier launch sent), or nil when the source can't read it.
    func attachmentData(_ attachment: AgentAttachment) async -> Data?
}

extension AgentSessionSource {
    public func attachmentData(_ attachment: AgentAttachment) async -> Data? { nil }
}

extension AgentSessionSource {
    /// Off unless a source lists and restores checkpoints itself (the phone
    /// link does not carry them yet).
    public var supportsCheckpoints: Bool { false }

    public func checkpoints() async throws -> [AgentCheckpoint] {
        throw AgentFeatureUnavailable("This session has no checkpoints.")
    }

    public func restore(_ checkpoint: AgentCheckpoint) async throws -> String {
        throw AgentFeatureUnavailable("This session can't restore checkpoints.")
    }

    public func handoffTargets() async throws -> [AgentHandoffTarget] {
        throw AgentFeatureUnavailable("This session can't continue in another agent.")
    }

    public func prepareHandoff(to target: AgentHandoffTarget) async throws -> AgentHandoffDraft {
        throw AgentFeatureUnavailable("This session can't continue in another agent.")
    }

    public func startHandoff(_ draft: AgentHandoffDraft) async throws -> AgentHandoffReceipt {
        throw AgentFeatureUnavailable("This session can't continue in another agent.")
    }

    public func discardHandoff(_ draft: AgentHandoffDraft) async {}

    /// Sources without their own files say so; never sample files.
    public var artifactSource: any ArtifactSource { UnavailableArtifactSource() }
}

/// An agent tab with no session behind it: no Mac is linked (or this build
/// has no mock data). It says so instead of streaming a made-up session.
@MainActor
public final class DisconnectedAgentSource: AgentSessionSource {
    public let summary: AgentSessionSummary
    private var continuations: [AsyncStream<AgentSessionEvent>.Continuation] = []

    public init(summary: AgentSessionSummary) {
        self.summary = summary
    }

    public var message: String {
        "\(summary.agentName) is on \(summary.macName). Connect to it to see this chat."
    }

    public func events() -> AsyncStream<AgentSessionEvent> {
        let (stream, continuation) = AsyncStream<AgentSessionEvent>.makeStream()
        continuation.yield(.clientError(message))
        continuations.append(continuation)
        return stream
    }

    /// Nothing to send to: say why again.
    public func send(_ intent: AgentClientIntent) {
        for continuation in continuations { continuation.yield(.clientError(message)) }
    }
}
