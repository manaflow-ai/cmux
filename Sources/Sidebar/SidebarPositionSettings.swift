import CoreGraphics

enum SidebarPositionSettings {
    static let key = "sidebarPosition"
    static let defaultPosition = SidebarPositionOption.left
    static let horizontalBarHeight: CGFloat = 48

    static func resolved(rawValue: String?) -> SidebarPositionOption {
        guard let rawValue else { return defaultPosition }
        return SidebarPositionOption(rawValue: rawValue) ?? defaultPosition
    }
}
