actor TokenSnapshot {
    private(set) var access: String?
    private(set) var refresh: String?

    func capture(access: String?, refresh: String?) {
        self.access = access
        self.refresh = refresh
    }
}
