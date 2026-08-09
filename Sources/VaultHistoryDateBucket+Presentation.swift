import CmuxVaultHistory
import Foundation

extension VaultHistoryDateBucket {
    var label: String {
        switch self {
        case .last24Hours:
            String(localized: "vaultHistory.bucket.last24Hours", defaultValue: "Last 24 hours")
        case .yesterday:
            String(localized: "vaultHistory.bucket.yesterday", defaultValue: "Yesterday")
        case .thisWeek:
            String(localized: "vaultHistory.bucket.thisWeek", defaultValue: "This week")
        case .thisMonth:
            String(localized: "vaultHistory.bucket.thisMonth", defaultValue: "This month")
        case .older:
            String(localized: "vaultHistory.bucket.older", defaultValue: "Older")
        }
    }
}
