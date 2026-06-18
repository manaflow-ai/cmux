import Foundation

enum BrowserPanelReloadMode {
    case soft
    case hard

    var recoveryCachePolicy: URLRequest.CachePolicy {
        switch self {
        case .soft:
            return .useProtocolCachePolicy
        case .hard:
            return .reloadIgnoringLocalCacheData
        }
    }
}
