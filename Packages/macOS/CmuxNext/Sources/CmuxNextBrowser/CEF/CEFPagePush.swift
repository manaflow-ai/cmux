import Foundation

/// The page push channel of one CEF tab (`cmux_shim_tab_page_push`, fork API 43): a string
/// to the receiver the tab's cmux-page document registered with `cmuxPageListen`. The page gets it as data,
/// with no script and no answer, as Chrome's WebUI pages get Mojo messages instead of
/// `WebUI::CallJavascriptFunction` scripts (content/browser/webui/web_ui_impl.cc).
@MainActor
public struct CEFPagePush {
    private let tab: CEFTab

    /// - Parameter tab: The tab whose document gets the pushes.
    public init(tab: CEFTab) {
        self.tab = tab
    }

    /// Whether ``send(_:)`` sends: the fork and the shim have the channel (``CEFForkFeatures/pagePush``).
    public var isAvailable: Bool { tab.runtime.forkFeatures.pagePush }

    /// Hands `text` to the document's receiver, in call order. Nothing is sent without the channel, before the
    /// browser exists or once the tab closed.
    public func send(_ text: String) {
        guard isAvailable, let browserID = tab.browserID, !tab.isClosed, let push = tab.runtime.shim?.tabPagePush else { return }
        // A post in host mode: the answer means nothing there, so no caller reads it (chromium-host-ops.json).
        _ = push(browserID, text)
    }
}
