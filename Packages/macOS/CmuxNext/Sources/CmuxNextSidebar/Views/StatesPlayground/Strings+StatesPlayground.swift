import Foundation

/// The Sidebar States Playground's own strings (DEV and NIGHTLY, Debug menu > Sidebar States Playground).
extension Strings {
    static var statesPlaygroundTitle: String {
        String(localized: "sidebar.statesPlayground.windowTitle", defaultValue: "Sidebar States Playground", bundle: .module)
    }
    static var statesPlaygroundRefresh: String {
        String(localized: "sidebar.statesPlayground.refresh", defaultValue: "Draw Again", bundle: .module)
    }
    /// How to read a sheet: the two guides and the numbers under each row.
    static var statesPlaygroundLegend: String {
        String(localized: "sidebar.statesPlayground.legend",
               defaultValue: "Pink line: trailing mark column. Teal line: leading inset. Under each row, each trailing mark from left to right: frame / ink, in points.",
               bundle: .module)
    }
    /// A favicon styles sheet's title: "Favicon style: Adaptive tint (default) · Dark" (`sidebar.faviconStyle`, Lawrence msg 19869).
    static func statesPlaygroundFaviconStyle(_ style: String, appearance: String) -> String {
        String(format: String(localized: "sidebar.statesPlayground.faviconStyleSheet", defaultValue: "Favicon style: %1$@ · %2$@", bundle: .module),
               style, appearance)
    }
    /// A section sheet's title: the section's, then the appearance ("Home filter · Dark").
    static func statesPlaygroundSection(_ title: String, _ appearance: String) -> String {
        String(format: String(localized: "sidebar.statesPlayground.section", defaultValue: "%1$@ · %2$@", bundle: .module), title, appearance)
    }
    /// A cell whose row the sidebar did not draw.
    static var statesPlaygroundNotDrawn: String {
        String(localized: "sidebar.statesPlayground.notDrawn", defaultValue: "Not drawn", bundle: .module)
    }
}
