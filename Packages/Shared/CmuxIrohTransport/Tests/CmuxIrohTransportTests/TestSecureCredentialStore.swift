import Foundation
@testable import CmuxIrohTransport

actor TestSecureCredentialStore: CmxIrohSecureCredentialStoring {
    private var records: [String: Data] = [:]
    private var accessibilities: [CmxIrohSecureCredentialAccessibility] = []
    private var storedDeleteAllCount = 0
    private var storedReadCount = 0
    private var lastAccount: String?

    func read(account: String) -> Data? {
        storedReadCount += 1
        lastAccount = account
        return records[account]
    }

    func write(
        _ data: Data,
        account: String,
        accessibility: CmxIrohSecureCredentialAccessibility
    ) {
        records[account] = data
        accessibilities.append(accessibility)
        lastAccount = account
    }

    func delete(account: String) {
        records.removeValue(forKey: account)
        lastAccount = account
    }

    func deleteAll() {
        records.removeAll()
        storedDeleteAllCount += 1
    }

    func seed(_ data: Data, account: String) {
        records[account] = data
    }

    func recordCount() -> Int {
        records.count
    }

    func observedAccessibilities() -> [CmxIrohSecureCredentialAccessibility] {
        accessibilities
    }

    func deleteAllCount() -> Int {
        storedDeleteAllCount
    }

    func readCount() -> Int {
        storedReadCount
    }

    func lastDeletedOrWrittenAccount() -> String? {
        lastAccount
    }

    func onlyStoredData() -> Data? {
        guard records.count == 1 else { return nil }
        return records.values.first
    }
}
