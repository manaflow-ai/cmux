/// Mutable connectivity probe for auth tests that flip online state mid-flow.
actor ConnectivityProbe {
    private var online: Bool

    init(isOnline: Bool) {
        self.online = isOnline
    }

    func setOnline(_ value: Bool) {
        online = value
    }

    func isOnline() -> Bool {
        online
    }
}
