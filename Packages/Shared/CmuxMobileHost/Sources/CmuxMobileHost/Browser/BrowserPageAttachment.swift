import CmuxBrowserStream
public import Foundation

/// One phone attached to one Mac browser tab. The page owner (the app's
/// CEF or WebKit tab) applies everything; the handler only checks policy.
public protocol BrowserPageAttachment: Sendable {
    var geometry: BrowserPageGeometry { get async }
    var video: any BrowserVideoSource { get }
    /// Page state, cursor, focus and copies; the first element is the current page.
    func events() async -> AsyncStream<BrowserPageEvent>
    /// One input event in page CSS pixels, in order.
    func apply(_ input: RbInputEvent) async
    /// Loads an http(s) URL the handler already checked.
    func load(_ url: URL) async throws
    func history(_ op: RbHistoryOp) async
    /// The phone's clipboard, pushed right before a paste.
    func pasteboard(_ items: [RbClipboardItem]) async
    func setVisible(_ visible: Bool) async
    func detach() async
}
