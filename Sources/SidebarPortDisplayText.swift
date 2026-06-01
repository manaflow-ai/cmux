import Foundation

enum SidebarPortDisplayText {
    static func label(for port: Int) -> String {
        String(
            format: String(localized: "sidebar.port.label", defaultValue: ":%lld"),
            Int64(port)
        )
    }

    static func openTooltip(for port: Int) -> String {
        String(
            format: String(localized: "sidebar.port.openTooltip", defaultValue: "Open localhost:%lld"),
            Int64(port)
        )
    }
}
