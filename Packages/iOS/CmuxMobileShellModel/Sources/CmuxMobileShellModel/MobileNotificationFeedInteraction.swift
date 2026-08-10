/// An action the mobile Feed can deliver to the item’s owning Mac.
public enum MobileNotificationFeedInteraction: Equatable, Sendable {
    /// Sends free-form text to the exact terminal surface.
    case terminalReply
    /// Resolves a pending tool permission request.
    case permission(requestID: String)
    /// Resolves a pending plan review, optionally with revision feedback.
    case exitPlan(requestID: String, defaultMode: MobileFeedExitPlanMode)
    /// Answers every prompt in a pending agent question request.
    case questions(requestID: String, prompts: [MobileFeedQuestionPrompt])
}

/// A tool-permission decision supported by the agent hook protocol.
public enum MobileFeedPermissionMode: String, CaseIterable, Equatable, Hashable, Sendable {
    case once
    case always
    case all
    case bypass
    case deny
}

/// A plan-review decision supported by the agent hook protocol.
public enum MobileFeedExitPlanMode: String, CaseIterable, Equatable, Hashable, Sendable {
    case ultraplan
    case bypassPermissions
    case autoAccept
    case manual
    case deny
}

/// One question in a possibly multi-question agent request.
public struct MobileFeedQuestionPrompt: Identifiable, Equatable, Sendable {
    public let id: String
    public let header: String?
    public let prompt: String
    public let allowsMultipleSelections: Bool
    public let options: [MobileFeedQuestionOption]

    public init(
        id: String,
        header: String?,
        prompt: String,
        allowsMultipleSelections: Bool,
        options: [MobileFeedQuestionOption]
    ) {
        self.id = id
        self.header = header
        self.prompt = prompt
        self.allowsMultipleSelections = allowsMultipleSelections
        self.options = options
    }
}

/// One preset answer for an agent question.
public struct MobileFeedQuestionOption: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let detail: String?

    public init(id: String, label: String, detail: String?) {
        self.id = id
        self.label = label
        self.detail = detail
    }
}
