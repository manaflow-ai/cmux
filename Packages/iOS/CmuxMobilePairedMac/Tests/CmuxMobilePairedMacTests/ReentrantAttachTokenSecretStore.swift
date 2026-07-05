@testable import CmuxMobilePairedMac

// Test instances are owned by one test and called through the store actor.
final class ReentrantAttachTokenSecretStore: MobileAttachTokenSecretStoring, @unchecked Sendable {
    private var tokensByAccount: [String: String] = [:]
    var onSave: (@Sendable () -> Void)?

    func readAttachToken(account: String) -> String? {
        tokensByAccount[account]
    }

    func saveAttachToken(_ token: String, account: String) -> Bool {
        onSave?()
        tokensByAccount[account] = token
        return true
    }

    func deleteAttachToken(account: String) {
        tokensByAccount.removeValue(forKey: account)
    }

    func snapshot() -> [String: String] {
        tokensByAccount
    }
}
