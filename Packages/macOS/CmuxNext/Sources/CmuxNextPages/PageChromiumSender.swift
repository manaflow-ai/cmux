public import Foundation

/// The frame a page channel message came from (``PageChromiumEvent/hostMessage(_:_:)``): what the
/// browser process knows of the frame that delivered it, never what the message says. Chrome's
/// WebUI takes a `chrome.send` sender the same way and drops a message whose frame's last
/// committed URL is not WebUI (content/browser/webui/web_ui_impl.cc, `WebUIImpl::Send`).
public nonisolated struct PageChromiumSender: Sendable, Equatable {
    /// The Chromium browser of the delivering frame.
    public var browserID: Int
    /// The delivering frame is the main frame.
    public var isMainFrame: Bool
    /// The delivering frame's last committed document URL; nil before any commit.
    public var url: URL?

    /// - Parameters:
    ///   - browserID: The Chromium browser of the delivering frame.
    ///   - isMainFrame: The delivering frame is the main frame.
    ///   - url: The delivering frame's last committed document URL.
    public init(browserID: Int, isMainFrame: Bool, url: URL?) {
        self.browserID = browserID
        self.isMainFrame = isMainFrame
        self.url = url
    }
}
