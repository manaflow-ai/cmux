import Foundation

nonisolated enum BrowserFaviconPanelState: Equatable, Sendable {
    case empty
    case resolving(BrowserFaviconRequest)
    case resolved(BrowserFaviconRequest, pngData: Data)
    case failed(BrowserFaviconRequest)

    var pngData: Data? {
        guard case .resolved(_, let pngData) = self else { return nil }
        return pngData
    }

    func shouldStartResolution(for request: BrowserFaviconRequest) -> Bool {
        switch self {
        case .empty:
            return true
        case .resolving(let current), .resolved(let current, _):
            return current != request
        case .failed:
            return true
        }
    }
}
