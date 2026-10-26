public import Foundation

/// What a cmux page tab tells its page host (``CEFTab/pageEvents``). On renderer paths (fork API
/// 29), where the page opens no DevTools session, the browser process also reports the page's
/// posts to its host and its main-frame document events here.
public struct CEFPageTabEvents {
    /// A drag of these files from outside the app entered the page (a cmux page hands such a drop
    /// to its host); nil ignores it.
    public var filesDragged: (@MainActor ([URL]) -> Void)?
    /// A real mouse down or key down reached the page, at this `systemUptime` (a cmux page backs its
    /// calls with it as the person's gesture); nil ignores it.
    public var userInput: (@MainActor (TimeInterval) -> Void)?
    /// A post of the page host channel (``CEFPageSchemes/hostChannel``) from the tab's main frame
    /// (renderer paths).
    public var posted: (@MainActor (CEFPageHostPost) -> Void)?
    /// A main-frame document committed (OnLoadStart) at this URL (renderer paths).
    public var committed: (@MainActor (URL?) -> Void)?
    /// The main-frame document finished loading (OnLoadEnd) (renderer paths).
    public var finished: (@MainActor () -> Void)?

    public init(filesDragged: (@MainActor ([URL]) -> Void)? = nil, userInput: (@MainActor (TimeInterval) -> Void)? = nil,
                posted: (@MainActor (CEFPageHostPost) -> Void)? = nil, committed: (@MainActor (URL?) -> Void)? = nil,
                finished: (@MainActor () -> Void)? = nil) {
        self.filesDragged = filesDragged
        self.userInput = userInput
        self.posted = posted
        self.committed = committed
        self.finished = finished
    }
}

/// One post of a cmux page to its page host. The sender is what the browser knows of the frame that
/// delivered it (the tab's main frame and its last committed URL), never what the payload says
/// (`CEFRuntime` routes a page message by its browser and drops a page host post from a child frame).
public nonisolated struct CEFPageHostPost: Equatable, Sendable {
    /// The Chromium browser of the delivering frame.
    public var browserID: Int32
    /// The delivering main frame's last committed document URL.
    public var committedURL: URL?
    /// The post, untrusted data.
    public var payload: String
}
