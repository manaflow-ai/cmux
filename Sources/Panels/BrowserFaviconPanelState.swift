import Foundation

nonisolated enum BrowserFaviconPanelState: Equatable, Sendable {
    case empty
    case resolving(BrowserFaviconRequest, fallbackPNGData: Data?)
    case resolved(BrowserFaviconRequest, pngData: Data)
    case failed(BrowserFaviconRequest, fallbackPNGData: Data?)

    var pngData: Data? {
        switch self {
        case .empty:
            return nil
        case .resolving(_, let fallbackPNGData):
            return fallbackPNGData
        case .resolved(_, let pngData):
            return pngData
        case .failed(_, let fallbackPNGData):
            return fallbackPNGData
        }
    }

    func shouldStartResolution(for request: BrowserFaviconRequest) -> Bool {
        switch self {
        case .empty, .resolving(_, _):
            return true
        case .resolved(let current, _):
            return current != request
        case .failed(_, _):
            return true
        }
    }
}
