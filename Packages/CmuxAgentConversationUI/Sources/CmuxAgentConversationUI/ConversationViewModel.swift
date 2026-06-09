public import CmuxAgentConversation
public import Observation

/// The `@Observable` view model behind ``AgentChatView``.
///
/// It subscribes to a ``CmuxAgentConversation/ConversationSource``, holds the
/// current ``CmuxAgentConversation/Conversation``, and projects it into an array
/// of value-typed ``MessageRowSnapshot`` (pairing each tool call with its result
/// by id). Rows render only those snapshots plus a ``ChatRowActions`` closure
/// bundle, never this model — that is the snapshot-boundary contract.
///
/// ```swift
/// let model = ConversationViewModel(source: source)
/// await model.start()
/// ```
@Observable
@MainActor
public final class ConversationViewModel {
    /// The current parsed conversation.
    public private(set) var conversation: Conversation

    /// The projected rows to render, in conversation order.
    public private(set) var rows: [MessageRowSnapshot] = []

    /// Whether the initial load has completed.
    public private(set) var hasLoaded: Bool = false

    /// The source of conversation state and updates.
    private let source: any ConversationSource

    /// Call ids of tool-call rows the user has expanded.
    private var expandedToolCalls: Set<String> = []

    /// Creates a view model bound to a conversation source.
    ///
    /// - Parameter source: The source to render. Its first event seeds the view.
    public init(source: any ConversationSource) {
        self.source = source
        self.conversation = Conversation.empty(agentKind: .unknown, sessionId: "")
    }

    /// Subscribes to the source and projects each emission until the stream
    /// finishes or the calling task is cancelled.
    ///
    /// Drive this from a SwiftUI `.task { await model.run() }` so the
    /// subscription's lifetime is bound to the view: when the view disappears
    /// SwiftUI cancels the task, which ends the `for await` loop. There is no
    /// separate stored `Task`, so nothing can outlive the view.
    public func run() async {
        for await event in source.events {
            if Task.isCancelled { return }
            apply(event)
        }
    }

    /// Whether the tool-call row for the given call id is expanded.
    ///
    /// - Parameter callID: The call id to query.
    /// - Returns: `true` if the row is currently expanded.
    public func isToolCallExpanded(_ callID: String) -> Bool {
        expandedToolCalls.contains(callID)
    }

    /// Toggles the expanded/collapsed state of a tool-call row.
    ///
    /// - Parameter callID: The call id whose row to toggle.
    public func toggleToolCall(_ callID: String) {
        if expandedToolCalls.contains(callID) {
            expandedToolCalls.remove(callID)
        } else {
            expandedToolCalls.insert(callID)
        }
    }

    /// Applies one source event to the model state and re-projects rows.
    private func apply(_ event: ConversationEvent) {
        switch event {
        case let .snapshot(conversation):
            self.conversation = conversation
            self.rows = Self.project(conversation)
            self.hasLoaded = true
        case let .upsert(messages, seq):
            self.conversation = Self.merge(conversation, messages: messages, seq: seq)
            self.rows = Self.project(conversation)
            self.hasLoaded = true
        case .truncated:
            self.conversation = Conversation.empty(
                agentKind: conversation.agentKind,
                sessionId: conversation.sessionId
            )
            self.rows = []
        }
    }

    /// Merges upserted messages into a conversation by id (append-or-replace),
    /// preserving order and taking the newer `seq`.
    private static func merge(
        _ base: Conversation,
        messages: [Message],
        seq: UInt64
    ) -> Conversation {
        var merged = base.messages
        var indexByID = Dictionary(uniqueKeysWithValues: merged.enumerated().map { ($1.id, $0) })
        for message in messages {
            if let existing = indexByID[message.id] {
                merged[existing] = message
            } else {
                indexByID[message.id] = merged.count
                merged.append(message)
            }
        }
        return Conversation(
            id: base.id,
            agentKind: base.agentKind,
            sessionId: base.sessionId,
            messages: merged,
            seq: max(base.seq, seq)
        )
    }

    /// Projects a conversation into render rows, pairing each tool call with the
    /// result that shares its id.
    ///
    /// Results are matched to calls and folded into the call's row, so a
    /// standalone tool-result message never produces a second row. A result with
    /// no preceding call (rare/malformed) still renders as its own bubble so no
    /// content is dropped.
    private static func project(_ conversation: Conversation) -> [MessageRowSnapshot] {
        // Index results by call id so a call can absorb its output.
        var resultsByCallID: [String: ToolResult] = [:]
        for message in conversation.messages {
            for block in message.blocks {
                if case let .toolResult(result) = block {
                    resultsByCallID[result.toolUseID] = result
                }
            }
        }

        var rows: [MessageRowSnapshot] = []
        var consumedResultCallIDs: Set<String> = []

        for message in conversation.messages {
            for (blockIndex, block) in message.blocks.enumerated() {
                let rowID = "\(message.id)-\(blockIndex)"
                switch block {
                case let .text(text):
                    rows.append(bubbleRow(id: rowID, role: message.role, text: text))
                case let .reasoning(text):
                    rows.append(bubbleRow(id: rowID, role: .reasoning, text: text))
                case let .toolUse(use):
                    let result = resultsByCallID[use.id]
                    if result != nil { consumedResultCallIDs.insert(use.id) }
                    rows.append(toolCallRow(id: rowID, use: use, result: result))
                case let .toolResult(result):
                    // Already folded into its call's row; skip the duplicate.
                    guard !consumedResultCallIDs.contains(result.toolUseID) else { continue }
                    rows.append(orphanResultRow(id: rowID, result: result))
                    consumedResultCallIDs.insert(result.toolUseID)
                case let .image(image):
                    rows.append(
                        bubbleRow(
                            id: rowID,
                            role: message.role,
                            text: "",
                            imageCount: 1,
                            imageMediaType: image.mediaType
                        )
                    )
                }
            }
        }
        return rows
    }

    /// Builds a message-bubble row.
    private static func bubbleRow(
        id: String,
        role: MessageRole,
        text: String,
        imageCount: Int = 0,
        imageMediaType: String? = nil
    ) -> MessageRowSnapshot {
        MessageRowSnapshot(
            id: id,
            kind: .message(MessageBubbleSnapshot(role: role, text: text, imageCount: imageCount))
        )
    }

    /// Builds a tool-call row from a call and its optional result.
    private static func toolCallRow(
        id: String,
        use: ToolUse,
        result: ToolResult?
    ) -> MessageRowSnapshot {
        MessageRowSnapshot(
            id: id,
            kind: .toolCall(
                ToolCallSnapshot(
                    callID: use.id,
                    name: use.name,
                    inputSummary: use.inputSummary,
                    inputJSON: use.inputJSON,
                    resultText: result.map(Self.flatten),
                    isError: result?.isError ?? false
                )
            )
        )
    }

    /// Builds a row for a result with no matching call.
    private static func orphanResultRow(id: String, result: ToolResult) -> MessageRowSnapshot {
        MessageRowSnapshot(
            id: id,
            kind: .toolCall(
                ToolCallSnapshot(
                    callID: result.toolUseID,
                    name: result.toolUseID,
                    inputSummary: nil,
                    inputJSON: "",
                    resultText: Self.flatten(result),
                    isError: result.isError
                )
            )
        )
    }

    /// Flattens a tool result's blocks into displayable text.
    private static func flatten(_ result: ToolResult) -> String {
        result.blocks.compactMap { block -> String? in
            if case let .text(text) = block { return text }
            return nil
        }
        .joined(separator: "\n")
    }
}
