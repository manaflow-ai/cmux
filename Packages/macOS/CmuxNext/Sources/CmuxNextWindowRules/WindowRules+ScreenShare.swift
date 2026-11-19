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

    /// The device hub's record for a remote machine's screen, found by the screen id its own daemon reported.
    public nonisolated struct ScreenShareDevice: Encodable, Sendable {
        public var id: String
        public var platform: String?
        public var online: Bool

        public init(id: String, platform: String?, online: Bool) {
            self.id = id
            self.platform = platform
            self.online = online
        }
    }

    public nonisolated struct ScreenShareRoute: Decodable, Sendable {
        public var decision: String
        public var machineId: String?
        public var deviceId: String?
        public var reason: String?
    }

    /// Nil means the installed app FFI does not carry this operation yet. A remote machine's
    /// `authenticatedDeviceID` is the screen id its daemon's handshake reported; `device` is the hub's record of it.
    public func screenShare(machineID: String, kind: String, chat: ScreenShareChat,
                            authenticatedDeviceID: String? = nil, device: ScreenShareDevice? = nil) -> ScreenShareRoute? {
        struct Facts: Encodable {
            var machineId: String
            var kind: String
            var authenticatedDeviceId: String?
            var device: ScreenShareDevice?
            var chat: ScreenShareChat
        }
        return call("window_remote_screen_share", Facts(machineId: machineID, kind: kind, authenticatedDeviceId: authenticatedDeviceID,
                                                        device: device, chat: chat), as: ScreenShareRoute.self)
    }
}
