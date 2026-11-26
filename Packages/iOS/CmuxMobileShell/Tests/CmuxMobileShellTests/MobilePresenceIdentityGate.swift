actor MobilePresenceIdentityGate {
    private var account = "first"
    private let blockFirst: Bool
    private var calls = 0
    private var suspended: CheckedContinuation<String?, Never>?
    private var waiting: CheckedContinuation<Void, Never>?

    init(blockFirst: Bool = true) { self.blockFirst = blockFirst }

    func identity() async -> String? {
        calls += 1
        if blockFirst && calls == 1 {
            return await withCheckedContinuation { continuation in
                suspended = continuation
                waiting?.resume()
                waiting = nil
            }
        }
        return account
    }

    func waitForIdentityRequest() async {
        if suspended != nil { return }
        await withCheckedContinuation { waiting = $0 }
    }

    func releaseIdentity() {
        suspended?.resume(returning: account)
        suspended = nil
    }

    func callCount() -> Int { calls }
    func current() -> String? { account }
    func changeAccount() { account = "second" }
}
