actor RecordedAuthTokenSink {
    private var tokens: [String] = []

    func record(_ token: String?) {
        guard let token else { return }
        tokens.append(token)
    }

    func recordedTokens() -> [String] { tokens }
}
