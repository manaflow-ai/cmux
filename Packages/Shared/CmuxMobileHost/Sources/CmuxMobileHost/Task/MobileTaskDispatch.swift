/// A dispatch the policy validated. Every string is data: the runner passes
/// `prompt` to the harness as one ACP text block and `agent`, `model`,
/// `effort` only as values the Mac itself advertised.
public struct MobileTaskDispatch: Hashable, Sendable {
    public var agent: String
    public var model: String?
    public var effort: String?
    public var prompt: String
    /// An existing workspace of this host; nil asks the runner for a new one.
    public var workspace: String?
    /// `up_…` ids, resolved to `attachments` before the runner sees the request.
    public var uploads: [String]
    public var attachments: [MobileTaskAttachment]
    /// A label for the phone's template; never expanded on the Mac.
    public var template: String?

    public init(agent: String, model: String? = nil, effort: String? = nil, prompt: String, workspace: String? = nil,
                uploads: [String] = [], attachments: [MobileTaskAttachment] = [], template: String? = nil) {
        self.agent = agent
        self.model = model
        self.effort = effort
        self.prompt = prompt
        self.workspace = workspace
        self.uploads = uploads
        self.attachments = attachments
        self.template = template
    }
}
