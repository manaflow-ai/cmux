actor TokenSnapshot {
    private(set) var access: String?
    private(set) var refresh: String?
    private(set) var isAuthenticated: Bool?
    private(set) var currentUserID: String?
    private(set) var hasCachedTokens: Bool?

    func capture(
        access: String?,
        refresh: String?,
        isAuthenticated: Bool,
        currentUserID: String?,
        hasCachedTokens: Bool
    ) {
        self.access = access
        self.refresh = refresh
        self.isAuthenticated = isAuthenticated
        self.currentUserID = currentUserID
        self.hasCachedTokens = hasCachedTokens
    }
}
