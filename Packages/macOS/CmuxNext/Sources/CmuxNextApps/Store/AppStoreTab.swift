import Foundation

/// A tab of the App Store page (`appStore.show --tab`): the React page's `#/<tab>` route.
public nonisolated enum AppStoreTab: String, Sendable, Hashable, CaseIterable {
    /// The listings.
    case discover
    /// The installed apps: grants, Run sandboxed, Hide/Show, enable, remove, logs.
    case installed

    /// `appStore.show`'s `tab` argument, any case; nil for an empty or unknown name (the store
    /// opens as it is). `features` is unknown: cmux's features live in Settings (extensibility-DESIGN.md).
    public init?(argument: String) { self.init(rawValue: argument.trimmingCharacters(in: .whitespaces).lowercased()) }
}

extension AppStoreTab {
    /// The App Store's title (its tab and the palette entry).
    public static var storeTitle: String { AppsStrings.windowTitle }
}

extension AppStoreTab {
    /// The App Store page's fragment: a listing, else `tab` (Discover by default).
    public static func route(appID: String?, tab: AppStoreTab?) -> String {
        if let appID, var query = URLComponents(string: "x:") {
            query.queryItems = [URLQueryItem(name: "app", value: appID)]
            return "#/discover?" + (query.percentEncodedQuery ?? "")
        }
        return "#/" + (tab ?? .discover).rawValue
    }
}
