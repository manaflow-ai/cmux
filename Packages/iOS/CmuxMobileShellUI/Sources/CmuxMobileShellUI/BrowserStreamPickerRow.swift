import CMUXMobileCore
import CmuxMobileSupport
import Foundation

/// Immutable browser-panel row passed below the terminal picker's lazy menu boundary.
struct BrowserStreamPickerRow: Identifiable, Equatable {
    let id: String
    let label: String
    let subtitle: String

    init(_ descriptor: MobileBrowserPanelDescriptor) {
        id = descriptor.panelID
        let title = descriptor.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = descriptor.url.flatMap { URL(string: $0)?.host }
        if let title, !title.isEmpty {
            label = title
        } else {
            label = host ?? descriptor.url ?? descriptor.panelID
        }
        if descriptor.isLoading {
            subtitle = L10n.string("mobile.switchTab.status.loading", defaultValue: "Loading")
        } else {
            subtitle = host ?? L10n.string("mobile.switchTab.source.macBrowser", defaultValue: "Mac Browser")
        }
    }

    var destination: SurfaceSwitcherDestination {
        SurfaceSwitcherDestination(
            kind: .browserStream(id),
            title: label,
            subtitle: subtitle,
            systemImage: "display",
            accessibilityIdentifier: "BrowserStreamMenuItem-\(id)"
        )
    }
}
