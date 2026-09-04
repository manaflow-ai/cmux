import CmuxVaultHistory
import Foundation

extension VaultHistoryGroup {
    var title: String {
        switch identity {
        case let .date(bucket):
            bucket.label
        case .workspace:
            capturedTitle
                ?? String(localized: "vaultHistory.untitled", defaultValue: "Untitled")
        case .window:
            capturedTitle
                ?? String(localized: "vaultHistory.window", defaultValue: "Window")
        case let .agent(rawValue):
            SessionAgent(rawValue: rawValue)?.displayName
                ?? String(localized: "vaultHistory.group.other", defaultValue: "Other")
        case let .kind(kind):
            kind.label
        case .other:
            key == .agent
                ? String(localized: "vaultHistory.group.cmux", defaultValue: "cmux")
                : String(localized: "vaultHistory.group.other", defaultValue: "Other")
        }
    }

    private var capturedTitle: String? {
        events.lazy
            .map { $0.title.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
    }
}
