import Foundation

/// Home strings (Resources/Home.xcstrings).
nonisolated enum HomeStrings {
    static var title: String { String(localized: "home.title", defaultValue: "Home", table: "Home", bundle: .module) }
    static var unavailable: String {
        String(localized: "home.unavailable", defaultValue: "Conversations need a newer cmux daemon.", table: "Home", bundle: .module)
    }
    static var thisMacOnly: String { String(localized: "home.owner.local", defaultValue: "This Mac only", table: "Home", bundle: .module) }
}
