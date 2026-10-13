public import Foundation
public import Observation

/// What the pairing window shows. The App fills it from the WireGuard
/// phone host; this module never talks to the host itself.
@MainActor @Observable
public final class PhonePairingModel {
    public struct Phone: Identifiable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var model: String
        public var address: String
        public var connected: Bool
        public var lastSeen: Date?

        public init(id: String, name: String, model: String, address: String, connected: Bool, lastSeen: Date?) {
            self.id = id
            self.name = name
            self.model = model
            self.address = address
            self.connected = connected
            self.lastSeen = lastSeen
        }
    }

    /// The pairing link the QR code encodes; nil while none is minted.
    public var link: String?
    public var expiresAt: Date?
    /// UDP endpoints the phone will try.
    public var endpoints: [String] = []
    public var phones: [Phone] = []
    /// Name of the phone that just paired with the shown code.
    public var justPaired: String?
    /// Why phone access is off.
    public var failure: String?
    public var hostFingerprint = ""

    public var onNewCode: () -> Void = {}
    public var onRevoke: (String) -> Void = { _ in }

    public init() {}

    /// A demo model, for previews and the standalone check.
    public static func sample() -> PhonePairingModel {
        let model = PhonePairingModel()
        model.link = "cmux-next://pair#sample"
        model.expiresAt = Date().addingTimeInterval(600)
        model.endpoints = ["192.168.1.20:51888", "100.101.102.103:51888"]
        model.hostFingerprint = "A1B2-C3D4"
        model.phones = [
            Phone(id: "1", name: "Aziz's iPhone", model: "iPhone", address: "10.77.0.2", connected: true, lastSeen: Date()),
            Phone(id: "2", name: "Test iPhone", model: "iPhone", address: "10.77.0.3", connected: false,
                  lastSeen: Date().addingTimeInterval(-3600)),
        ]
        return model
    }
}
