import Foundation

/// Sub-navigation inside the Vault sidebar mode.
enum VaultPaneTab: String, CaseIterable, Identifiable {
    case sessions
    case history

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sessions:
            String(localized: "vaultPane.tab.sessions", defaultValue: "Sessions")
        case .history:
            String(localized: "vaultPane.tab.history", defaultValue: "History")
        }
    }

    var symbolName: String {
        switch self {
        case .sessions: "books.vertical"
        case .history: "clock.arrow.circlepath"
        }
    }
}
