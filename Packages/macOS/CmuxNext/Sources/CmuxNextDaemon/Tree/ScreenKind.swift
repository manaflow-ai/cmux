import Foundation

/// What a screen shows (`app-screens-v1`, plans/cmux-next/app-screens.md 1):
/// columns of panes (`workspace`, every screen of an older daemon) or one
/// app filling the screen (`app`, the only screen of an app workspace). Any
/// other kind (a newer daemon's, or the dropped `appColumn`) reads as
/// `workspace`, the shape older clients see.
public enum ScreenKind: String, Sendable, Hashable, Decodable {
    case workspace, app

    public init(from decoder: any Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .workspace
    }
}
