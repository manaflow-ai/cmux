import Foundation

struct BrowserWebExtensionsPresentationSnapshot: Equatable, Sendable {
    enum NotificationKey {
        static let panelID = "panelID"
        static let profileID = "profileID"
        static let item = "item"
    }

    enum State: Equatable, Sendable {
        case unsupported
        case loading
        case ready
    }

    struct Item: Identifiable, Equatable, Sendable {
        let id: String
        let name: String
        let hasAction: Bool
        let isToolbarPinned: Bool
        let isActionEnabled: Bool
        let badgeText: String
        let iconData: Data?
    }

    struct Failure: Identifiable, Equatable, Sendable {
        let id: String
        let entryName: String
        let message: String
    }

    let state: State
    let extensions: [Item]
    let failures: [Failure]
    let directoryPath: String

    static let loading = BrowserWebExtensionsPresentationSnapshot(
        state: .loading,
        extensions: [],
        failures: [],
        directoryPath: ""
    )

    static let unsupported = BrowserWebExtensionsPresentationSnapshot(
        state: .unsupported,
        extensions: [],
        failures: [],
        directoryPath: ""
    )
}
