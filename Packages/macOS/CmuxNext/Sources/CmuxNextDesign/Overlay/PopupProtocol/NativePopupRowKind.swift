import Foundation

/// NativePopupRowKind on the native popup wire.
public enum NativePopupRowKind: String, Codable, Equatable, Sendable {
    case `action`
    case `toggle`
    case `choice`
    case `section`
    case `separator`
    case `text`
    case `slider`
    case `submenu`
    case `textField`
}
