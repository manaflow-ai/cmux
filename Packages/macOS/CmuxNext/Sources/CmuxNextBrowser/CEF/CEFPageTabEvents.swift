public import Foundation

/// What a cmux page tab tells its page host (``CEFTab/pageEvents``). On renderer paths (fork API
/// 29), where the page opens no DevTools session, the browser process also reports the page's
/// main-frame document events here; its posts to its host come on the relay
/// (``CEFAgentRelay/onPageHostPost``).
public struct CEFPageTabEvents {
    /// A drag of these files from outside the app entered the page (a cmux page hands such a drop
    /// to its host); nil ignores it.
    public var filesDragged: (@MainActor ([URL]) -> Void)?
    /// A real mouse down or key down reached the page, at this `systemUptime` (a cmux page backs its
    /// calls with it as the person's gesture); nil ignores it.
    public var userInput: (@MainActor (TimeInterval) -> Void)?
    /// A main-frame document committed (OnLoadStart) at this URL (renderer paths).
    public var committed: (@MainActor (URL?) -> Void)?
    /// The main-frame document finished loading (OnLoadEnd) (renderer paths).
    public var finished: (@MainActor () -> Void)?

    public init(filesDragged: (@MainActor ([URL]) -> Void)? = nil, userInput: (@MainActor (TimeInterval) -> Void)? = nil,
                committed: (@MainActor (URL?) -> Void)? = nil, finished: (@MainActor () -> Void)? = nil) {
        self.filesDragged = filesDragged
        self.userInput = userInput
        self.committed = committed
        self.finished = finished
    }
}
