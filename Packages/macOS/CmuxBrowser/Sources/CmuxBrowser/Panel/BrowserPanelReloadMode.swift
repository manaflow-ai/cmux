public import Foundation

public enum BrowserPanelReloadMode {
    case soft
    case hard

    public var recoveryCachePolicy: URLRequest.CachePolicy {
        switch self {
        case .soft:
            return .useProtocolCachePolicy
        case .hard:
            return .reloadIgnoringLocalCacheData
        }
    }
}
