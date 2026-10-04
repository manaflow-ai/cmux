public import Foundation

/// Manifest v2 `presentation` (app-platform.md 16, app-screens.md 4): how an
/// app appears in the shell. Home, App Store and CodeRouter use the same
/// fields as every app; the Rust validator (`cmux-app-manifest`) checks them.
public nonisolated struct AppPresentation: Sendable, Hashable {
    /// Where the app's screen opens.
    public enum Screen: String, Sendable, Hashable {
        /// The app fills the screen (Home included; there is no app column).
        case app
    }

    /// The sidebar item that opens the app.
    public struct SidebarItem: Sendable, Hashable {
        /// `top`, `middle` or `bottom`.
        public var section: String
        /// Default: the app name.
        public var title: AppLocalizedText?
        /// Default: the app icon.
        public var icon: AppIcon?
        /// Lower first; 0-99 is first-party only.
        public var order: Int?
    }

    /// A web app: the URL in the browser engine with the app's own profile.
    public struct Web: Sendable, Hashable {
        public var url: URL
        /// `app`: a browser profile of this app only.
        public var profile: String
        /// Origins besides the url's own that the app may navigate to.
        public var origins: [String]
    }

    public var sidebarItem: SidebarItem?
    public var screen: Screen?
    /// The app may also open as a page tab.
    public var tab: Bool
    /// Where typing goes when nothing has focus: a CSS selector or a scene node id.
    public var primaryInput: String?
    public var web: Web?
    /// Installed but hidden until the user shows it (still in the palette,
    /// CLI and App Store). The supervisor reads the same field.
    public var hiddenByDefault: Bool

    init?(json: AppJSON?) {
        guard let json, case .object = json else { return nil }
        if let item = json["sidebarItem"], let section = item["section"]?.stringValue {
            sidebarItem = SidebarItem(section: section, title: AppLocalizedText(json: item["title"]), icon: AppIcon(json: item["icon"]),
                                      order: item["order"]?.numberValue.map { Int($0) })
        }
        screen = json["screen"]?.stringValue.flatMap(Screen.init(rawValue:))
        tab = json["tab"]?.boolValue ?? false
        primaryInput = json["primaryInput"]?.stringValue
        hiddenByDefault = json["hiddenByDefault"]?.boolValue ?? false
        if let web = json["web"], let url = web["url"]?.stringValue.flatMap(URL.init(string:)) {
            self.web = Web(url: url, profile: web["profile"]?.stringValue ?? "app",
                           origins: web["origins"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        }
    }
}
