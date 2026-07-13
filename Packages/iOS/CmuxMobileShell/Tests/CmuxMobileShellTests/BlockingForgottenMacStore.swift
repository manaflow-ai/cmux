import CmuxMobileShell

actor BlockingForgottenMacStore: PairedMacForgottenStoring {
    private var loadStarted = false
    private var loadStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var loadWaiters: [CheckedContinuation<Void, Never>] = []
    private var idsByScope: [String: Set<String>] = [:]

    func load(scope: String) async -> Set<String> {
        loadStarted = true
        loadStartWaiters.forEach { $0.resume() }
        loadStartWaiters.removeAll()
        await withCheckedContinuation { loadWaiters.append($0) }
        return idsByScope[scope] ?? []
    }

    func save(_ ids: Set<String>, scope: String) async {
        idsByScope[scope] = ids
    }

    func removeAll() async {
        idsByScope.removeAll()
    }

    func waitUntilLoadStarted() async {
        if loadStarted { return }
        await withCheckedContinuation { loadStartWaiters.append($0) }
    }

    func releaseLoads() {
        loadWaiters.forEach { $0.resume() }
        loadWaiters.removeAll()
    }
}
