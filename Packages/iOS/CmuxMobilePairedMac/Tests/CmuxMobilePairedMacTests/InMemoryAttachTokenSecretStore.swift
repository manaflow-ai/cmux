@testable import CmuxMobilePairedMac

actor InMemoryAttachTokenSecretStore: MobileAttachTokenSecretStoring {
    private var tokensByAccount: [String: String] = [:]

    func readAttachToken(account: String) async -> String? {
        tokensByAccount[account]
    }

    func saveAttachToken(_ token: String, account: String) async -> Bool {
        tokensByAccount[account] = token
        return true
    }

    func deleteAttachToken(account: String) async {
        tokensByAccount.removeValue(forKey: account)
    }

    func snapshot() -> [String: String] {
        tokensByAccount
    }
}
