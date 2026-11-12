public import Foundation

public struct BrowserImageCopyPasteboardPayload {
    public let imageData: Data
    public let mimeType: String?
    public let sourceURL: URL?

    public init(
        imageData: Data,
        mimeType: String?,
        sourceURL: URL?
    ) {
        self.imageData = imageData
        self.mimeType = mimeType
        self.sourceURL = sourceURL
    }
}
