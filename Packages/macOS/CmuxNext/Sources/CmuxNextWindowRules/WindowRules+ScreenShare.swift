extension WindowRules {
    /// Native host facts for one chat. Rust decides the route; the page supplies no machine identity.
    public nonisolated struct ScreenShareChat: Encodable, Sendable {
        public var expectedSessionId: String
        public var sessionId: String
        public var host: String
        public var hostKind: String
        public var peer: String?
        public var registryHost: String?
        public var localSummaryCurrent: Bool

        public init(expectedSessionId: String, sessionId: String, host: String, hostKind: String, peer: String?, registryHost: String?, localSummaryCurrent: Bool) {
            self.expectedSessionId = expectedSessionId
            self.sessionId = sessionId
            self.host = host
            self.hostKind = hostKind
            self.peer = peer
            self.registryHost = registryHost
            self.localSummaryCurrent = localSummaryCurrent
        }
    }

    public nonisolated struct ScreenShareRoute: Decodable, Sendable {
        public var decision: String
        public var machineId: String?
        public var deviceId: String?
        public var reason: String?
    }

    /// Nil means the installed app FFI does not carry this operation yet.
    public func screenShare(machineID: String, kind: String, chat: ScreenShareChat) -> ScreenShareRoute? {
        struct Facts: Encodable {
            var machineId: String
            var kind: String
            var chat: ScreenShareChat
        }
        return call("window_remote_screen_share", Facts(machineId: machineID, kind: kind, chat: chat), as: ScreenShareRoute.self)
    }
}
