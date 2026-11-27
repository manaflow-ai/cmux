import Foundation

/// What the Publish popover (``BrowserPublishPopover``) shows for a name and an audience: the App
/// asks its rules (the Apps tier's Rust, RFD 0003 E-A) and maps the answer to this, so the browser
/// package draws a publish without knowing the tier.
public struct BrowserPublishForm: Equatable, Sendable {
    /// Why Publish cannot run.
    public enum Problem: Equatable, Sendable {
        /// The name has no letter or digit, so it makes no address.
        case nameEmpty
        /// Any other reason the rules give, by its code.
        case other(String)
    }

    /// The address label the name makes (`a-<slug>--…`); nil when it makes none.
    public var hostLabel: String?
    /// The start command row ("Inferred from port 3000 on dev-box").
    public var startFrom: String
    public var canPublish: Bool
    public var problem: Problem?

    public init(hostLabel: String?, startFrom: String, canPublish: Bool, problem: Problem?) {
        self.hostLabel = hostLabel
        self.startFrom = startFrom
        self.canPublish = canPublish
        self.problem = problem
    }
}

/// How a publish ended, as the popover shows it.
public enum BrowserPublishAnswer: Equatable, Sendable {
    /// Live at `url` (Open shows it).
    case published(URL)
    /// The publish refused or failed: its code and message.
    case failed(code: String, message: String)
    /// The run ended with `exit` but its answer was not one the rules read.
    case unreadable(exit: Int)
    /// The machine could not be reached to run it.
    case unreachable(String)
}

/// The page's publish, as the App provides it to the popover.
public struct BrowserPublishSource {
    /// The name the field starts with.
    public var suggestedName: String
    /// The form for a typed name (nil: the suggested one) and an audience; nil when the rules cannot say.
    public var form: @MainActor (_ name: String?, _ team: Bool) -> BrowserPublishForm?
    /// Runs the publish.
    public var publish: @MainActor (_ name: String?, _ team: Bool) async -> BrowserPublishAnswer
    /// Shows the published app.
    public var open: @MainActor (URL) -> Void

    public init(suggestedName: String,
                form: @escaping @MainActor (String?, Bool) -> BrowserPublishForm?,
                publish: @escaping @MainActor (String?, Bool) async -> BrowserPublishAnswer,
                open: @escaping @MainActor (URL) -> Void) {
        self.suggestedName = suggestedName
        self.form = form
        self.publish = publish
        self.open = open
    }
}
