import Foundation
@testable import CmuxIrohTransport

actor TestControllableSecureIdentityStore: CmxIrohSecureIdentityStoring {
    private var records: [String: Data] = [:]
    private var shouldSuspendNextWrite = false
    private var suspendedWrite: CheckedContinuation<Void, Never>?
    private var writeSuspensionWaiters: [CheckedContinuation<Void, Never>] = []

    func read(account: String) -> Data? {
        records[account]
    }

    func write(_ data: Data, account: String) async {
        if shouldSuspendNextWrite {
            shouldSuspendNextWrite = false
            await withCheckedContinuation { continuation in
                suspendedWrite = continuation
                let waiters = writeSuspensionWaiters
                writeSuspensionWaiters.removeAll(keepingCapacity: false)
                for waiter in waiters { waiter.resume() }
            }
        }
        records[account] = data
    }

    func delete(account: String) {
        records.removeValue(forKey: account)
    }

    func deleteAll() {
        records.removeAll(keepingCapacity: false)
    }

    func suspendNextWrite() {
        shouldSuspendNextWrite = true
    }

    func waitUntilWriteIsSuspended() async {
        guard suspendedWrite == nil else { return }
        await withCheckedContinuation { continuation in
            writeSuspensionWaiters.append(continuation)
        }
    }

    func resumeSuspendedWrite() {
        let continuation = suspendedWrite
        suspendedWrite = nil
        continuation?.resume()
    }

    func recordCount() -> Int {
        records.count
    }
}
