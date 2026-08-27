import Foundation

extension FilePreviewMode {
    var socketName: String {
        switch self {
        case .text:
            return "text"
        case .pdf:
            return "pdf"
        case .image:
            return "image"
        case .media:
            return "media"
        case .quickLook:
            return "quickLook"
        }
    }
}
