internal import Foundation

/// The outcome of applying a v1 `right_sidebar` remote command app-side
/// (parse and apply both stay in the app: `RightSidebarRemoteRequest` is
/// shared with the socket focus-policy path).
public enum ControlSidebarRightSidebarResolution: Sendable, Equatable {
    /// The command applied; reply `OK`.
    case ok
    /// A `get`-style command returned sidebar state to encode.
    case state(visible: Bool, modeRawValue: String)
    /// `find_status` returned the Find query and totals to encode.
    case findStatus(ControlSidebarFindStatus)
    /// A parse or apply failure; `message` is the full legacy reply line
    /// (localized app-side where the original was localized).
    case failure(message: String)
}

/// The Find state `right_sidebar find_status` reports, so a script can wait
/// for a search and assert its totals.
public struct ControlSidebarFindStatus: Sendable, Equatable {
    public let query: String
    public let isRegex: Bool
    public let isCaseSensitive: Bool
    public let matchesWholeWord: Bool
    /// `idle`, `searching`, `completed`, `limited` or `failed`.
    public let phase: String
    public let results: Int
    public let files: Int
    /// The status line as shown, or nil when hidden.
    public let message: String?

    public init(
        query: String,
        isRegex: Bool,
        isCaseSensitive: Bool,
        matchesWholeWord: Bool,
        phase: String,
        results: Int,
        files: Int,
        message: String?
    ) {
        self.query = query
        self.isRegex = isRegex
        self.isCaseSensitive = isCaseSensitive
        self.matchesWholeWord = matchesWholeWord
        self.phase = phase
        self.results = results
        self.files = files
        self.message = message
    }
}
