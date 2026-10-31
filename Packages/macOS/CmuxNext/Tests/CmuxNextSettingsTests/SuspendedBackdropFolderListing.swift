import CmuxNextDesign

/// A deliberately suspended filesystem substitute: tests release each read without sleeps or polling.
actor SuspendedBackdropFolderListing {
    private var immediatePaths: Set<String> = []
    private var reads: [String: Int] = [:]
    private var pending: [String: CheckedContinuation<[BackdropSelection], Never>] = [:]
    private var waiting: [String: (count: Int, continuation: CheckedContinuation<Void, Never>)] = [:]

    func list(_ path: String) async -> [BackdropSelection] {
        if immediatePaths.contains(path) { return immediateList(path) }
        return await withCheckedContinuation { continuation in
            pending[path] = continuation
            reads[path, default: 0] += 1
            if let waiter = waiting[path], reads[path, default: 0] >= waiter.count {
                waiting.removeValue(forKey: path)?.continuation.resume()
            }
        }
    }

    func useImmediateResults(for path: String) { immediatePaths.insert(path) }

    func immediateList(_ path: String) -> [BackdropSelection] {
        reads[path, default: 0] += 1
        return [.art(reads[path] == 1 ? .munchScream : .hokusaiGreatWave)]
    }

    func started(_ path: String, count: Int) async {
        if reads[path, default: 0] >= count { return }
        await withCheckedContinuation { waiting[path] = (count, $0) }
    }

    func count(_ path: String) -> Int { reads[path, default: 0] }

    func finish(_ path: String, pictures: [BackdropSelection]) {
        pending.removeValue(forKey: path)?.resume(returning: pictures)
    }
}
