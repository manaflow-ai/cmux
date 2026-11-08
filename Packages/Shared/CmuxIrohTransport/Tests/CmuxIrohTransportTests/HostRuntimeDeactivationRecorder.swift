import Foundation

actor HostRuntimeDeactivationRecorder {
    private var recorded: [String?] = []
    private var waiters: [
        (count: Int, continuation: CheckedContinuation<Void, Never>)
    ] = []

    func record(_ bindingID: String?) {
        recorded.append(bindingID)
        let ready = waiters.filter { recorded.count >= $0.count }
        waiters.removeAll { recorded.count >= $0.count }
        for waiter in ready { waiter.continuation.resume() }
    }

    func waitForCount(_ count: Int) async {
        if recorded.count >= count { return }
        await withCheckedContinuation { continuation in
            waiters.append((count, continuation))
        }
    }

    func values() -> [String?] { recorded }
}
