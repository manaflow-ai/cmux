import Foundation

/// What an app tab shows (`app-screens-v1`, raw `Tab.app`): the app by its
/// manifest id and the tab's bounded route. The store never reads app
/// content; the app renders its own page.
public struct AppTabRef: Sendable, Hashable, Codable {
    /// The app id as its manifest names it (`publisher/name`).
    public var app: String
    /// The tab's route (client state, at most 4096 bytes); nil for the app's start.
    public var route: String?

    public init(app: String, route: String? = nil) {
        self.app = app
        self.route = route
    }
}
