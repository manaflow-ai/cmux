import Foundation

/// The "Done (N)" row (`SidebarLayout+DoneFold`; Resources/Localizable.xcstrings).
extension Strings {
    static func doneFold(_ count: Int) -> String {
        String(localized: "sidebar.doneFold.title", defaultValue: "Done (\(count))", bundle: .module)
    }
}
