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
    /// A cell whose row the sidebar did not draw.
    static var statesPlaygroundNotDrawn: String {
        String(localized: "sidebar.statesPlayground.notDrawn", defaultValue: "Not drawn", bundle: .module)
    }
}
