#if canImport(UIKit)
import Foundation
import WebKit

/// Safety: WebKit owns this callback token and permits asynchronous responses;
/// `MobileDiffSchemeTaskLifetime` serializes callbacks with cancellation.
final class MobileDiffPendingSchemeTask: @unchecked Sendable {
    private let task: any WKURLSchemeTask

    init(_ task: any WKURLSchemeTask) {
        self.task = task
    }

    func fail(with error: any Error) {
        task.didFailWithError(error)
    }

    func finish(url: URL, content: MobileDiffPatchContent) {
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "\(content.mimeType); charset=utf-8",
                "Cache-Control": "no-store",
                "X-Content-Type-Options": "nosniff",
                "Cross-Origin-Resource-Policy": "same-origin",
            ]
        )!
        task.didReceive(response)
        task.didReceive(content.data)
        task.didFinish()
    }
}
#endif
