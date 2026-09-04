/// One unsolicited event received from the Chrome DevTools Protocol.
struct CDPEvent: Codable, Equatable, Sendable {
    let method: String
    let params: CDPValue?

    init(method: String, params: CDPValue? = nil) {
        self.method = method
        self.params = params
    }
}
