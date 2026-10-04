public import Foundation

/// The trust rule of every engine: only the page's own top-level document may talk to the host.
public nonisolated enum PageHostTrust {
    public static let handlerName = "cmuxPage"

    public static func isTrusted(_ message: PageHostMessage, page: PageDescriptor) -> Bool {
        message.isMainFrame && page.owns(message.frameURL)
    }
}
