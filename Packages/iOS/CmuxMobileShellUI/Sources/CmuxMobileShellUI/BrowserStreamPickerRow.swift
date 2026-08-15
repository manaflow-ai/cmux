import CMUXMobileCore
import Foundation

/// Immutable browser-panel row passed below the terminal picker's lazy menu boundary.
struct BrowserStreamPickerRow: Identifiable, Equatable {
    let id: String
    let label: String

    init(_ descriptor: MobileBrowserPanelDescriptor) {
        id = descriptor.panelID
        let title = descriptor.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = descriptor.url.flatMap { URL(string: $0)?.host }
        if let title, !title.isEmpty {
            label = title
        } else {
            label = host ?? descriptor.url ?? descriptor.panelID
        }
    }
}
