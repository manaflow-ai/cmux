import Foundation
@testable import CmuxIrohTransport

enum TestControllableSecureCredentialStoreError: Error, Equatable {
    case writeFailed
}

actor TestControllableSecureCredentialStore: CmxIrohSecureCredentialStoring {
    private enum NextWrite {
        case normal
        case suspended
        case failed
    }

    private var records: [String: Data] = [:]
    private var nextWrite = NextWrite.normal
    private var suspendedWrite: CheckedContinuation<Void, Never>?
    private var writeSuspensionWaiters: [CheckedContinuation<Void, Never>] = []

    func read(account: String) -> Data? {
        records[account]
    }

    func write(
        _ data: Data,
        account: String,
        accessibility _: CmxIrohSecureCredentialAccessibility
    ) async throws {
        let behavior = nextWrite
        nextWrite = .normal
        switch behavior {
        case .normal:
            break
        case .suspended:
            await withCheckedContinuation { continuation in
                suspendedWrite = continuation
                let waiters = writeSuspensionWaiters
                writeSuspensionWaiters.removeAll(keepingCapacity: false)
                for waiter in waiters { waiter.resume() }
            }
        case .failed:
            throw TestControllableSecureCredentialStoreError.writeFailed
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
        nextWrite = .suspended
    }

    func failNextWrite() {
        nextWrite = .failed
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
}
