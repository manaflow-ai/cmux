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

    /// The store's route (the React page's fragment, the native store reads it too): a listing,
    /// else `tab` (Discover by default).
    public nonisolated static func route(appID: String?, tab: AppStoreTab?) -> String {
        if let appID, var query = URLComponents(string: "x:") {
            query.queryItems = [URLQueryItem(name: "app", value: appID)]
            return "#/discover?" + (query.percentEncodedQuery ?? "")
        }
        return "#/" + (tab ?? .discover).rawValue
    }

    /// A route's listing and tab (``route(appID:tab:)`` read back); nil parts for what it does not name.
    public nonisolated static func parse(route: String) -> (appID: String?, tab: AppStoreTab?) {
        let text = route.hasPrefix("#") ? String(route.dropFirst()) : route
        let parts = text.split(separator: "?", maxSplits: 1).map(String.init)
        let tab = parts.first.flatMap { AppStoreTab(argument: $0.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) }
        let app = parts.count > 1 ? URLComponents(string: "x:?" + parts[1])?.queryItems?.first { $0.name == "app" }?.value : nil
        return (app.flatMap { $0.isEmpty ? nil : $0 }, tab)
    }
}
