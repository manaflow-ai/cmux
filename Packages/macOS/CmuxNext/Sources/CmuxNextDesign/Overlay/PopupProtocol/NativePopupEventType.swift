import Foundation

/// NativePopupEventType on the native popup wire.
public enum NativePopupEventType: String, Codable, Equatable, Sendable {
    case `pick`
    case `change`
    case `search`
    case `highlight`
    case `complete`
    case `submit`
    case `dismiss`
    /// Left or Right asked for the previous or next rail tab (`value` is `previous` or `next`).
    case `navigate`
}
