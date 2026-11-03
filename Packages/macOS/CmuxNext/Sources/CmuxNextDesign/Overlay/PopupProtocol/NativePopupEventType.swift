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
}
