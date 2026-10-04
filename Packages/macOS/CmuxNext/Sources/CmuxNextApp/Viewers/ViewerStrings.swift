import Foundation

/// The viewers' text (Resources/Viewers.xcstrings).
enum ViewerStrings {
    private static func text(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "Viewers", bundle: .module)
    }

    static var noDiffViewer: String { text("viewers.noDiffViewer", "cmux-next has no diff viewer yet.") }
}
