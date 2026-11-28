public import Foundation

/// What the user asks the server to do. Intents only travel to the owner
/// (the `server` role, or `TeamDO` for approve and revoke); the model never
/// applies them locally, so every change on screen is the owner's echo.
public nonisolated enum ServerIntentKind: Sendable, Equatable {
    /// `server.up` / `server.down`.
    case setEnabled(Bool)
    /// `server.pair.begin`: a fresh code, QR and words.
    case showPairingCode
    /// Look up a pending pairing by code for the approver sheet.
    case lookupCode(String)
    /// `server.pair.approve {code, team, name}` (origin user only). With
    /// `placeChief` the app then places the user's Chief on the new server
    /// (`chief.update {brain_place}`, brains/DESIGN-cmux-lawrence.md G8).
    case approveCode(code: String, team: String, name: String, placeChief: Bool = false)
    /// `server.health.fix {check}` (origin user only).
    case fixCheck(HealthCheckID)
    /// Open the Health view (the App routes it).
    case openHealth
    /// `host.revoke` for a paired device's access.
    case revokeDevice(String)
}

/// One intent with its idempotency key.
public nonisolated struct ServerIntent: Sendable, Equatable, Identifiable {
    public var key: String
    public var kind: ServerIntentKind
    public var id: String { key }

    public init(kind: ServerIntentKind, key: String = UUID().uuidString) {
        self.kind = kind
        self.key = key
    }
}

/// Where the model gets server state. The App will supply a source over
/// the daemon's `server.status` stream; demos and tests use `MockServerSource`.
@MainActor
public protocol ServerSource: AnyObject {
    func start(_ sink: @escaping @MainActor (ServerSourceEvent) -> Void)
    func send(_ intent: ServerIntent)
    func stop()
}
