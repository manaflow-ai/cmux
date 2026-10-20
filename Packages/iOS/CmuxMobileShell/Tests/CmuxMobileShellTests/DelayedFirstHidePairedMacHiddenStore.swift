@testable import CmuxMobileShell

actor DelayedFirstHidePairedMacHiddenStore: PairedMacHiddenStoring {
    private var idsByScope: [String: Set<String>] = [:]
    private var didDelayHideSave = false
    private var hideSaveStarted = false
    private var hideSaveStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var hideSaveRelease: CheckedContinuation<Void, Never>?
    private var didSaveEmpty = false
    private var emptySaveWaiters: [CheckedContinuation<Void, Never>] = []

    func load(scope: String) async -> Set<String> {
        idsByScope[scope] ?? []
    }

    func save(_ ids: Set<String>, scope: String) async {
        if !didDelayHideSave, !ids.isEmpty {
            didDelayHideSave = true
            hideSaveStarted = true
            let waiters = hideSaveStartWaiters
            hideSaveStartWaiters = []
            for waiter in waiters {
                waiter.resume()
            }
            await withCheckedContinuation { continuation in
                hideSaveRelease = continuation
            }
        }
        if ids.isEmpty {
            idsByScope.removeValue(forKey: scope)
            didSaveEmpty = true
            let waiters = emptySaveWaiters
            emptySaveWaiters = []
            for waiter in waiters {
                waiter.resume()
            }
        } else {
            idsByScope[scope] = ids
        }
    }

    func removeAll() async {
        idsByScope.removeAll()
    }

    func waitForDelayedHideSave() async {
        guard !hideSaveStarted else { return }
        await withCheckedContinuation { continuation in
            hideSaveStartWaiters.append(continuation)
        }
    }

    func releaseDelayedHideSave() {
        hideSaveRelease?.resume()
        hideSaveRelease = nil
    }

    func waitForEmptySave() async {
        guard !didSaveEmpty else { return }
        await withCheckedContinuation { continuation in
            emptySaveWaiters.append(continuation)
        }
    }
}
