/// Test double for expected-user token binding.
actor TokenProbe {
    private var userIDs: [String?]
    private(set) var tokenReads = 0

    init(userIDs: [String?]) {
        self.userIDs = userIDs
    }

    func token() -> String? {
        tokenReads += 1
        return "token"
    }

    func currentUserID() -> String? {
        guard !userIDs.isEmpty else { return nil }
        return userIDs.removeFirst()
    }
}
