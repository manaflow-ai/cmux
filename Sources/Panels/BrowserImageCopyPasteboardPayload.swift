import Foundation

struct BrowserImageCopyPasteboardPayload {
    let imageData: Data
    let mimeType: String?
    let sourceURL: URL?
}
