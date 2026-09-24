public import Foundation

public struct BrowserImageCopyPasteboardPayload {
    public let imageData: Data
    public let mimeType: String?
    public let sourceURL: URL?
}
