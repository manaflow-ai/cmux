public import Foundation

/// The tunnel layout both apps agree on.
///
/// The Mac is 10.77.0.1. Paired phones get 10.77.0.2 through 10.77.0.254;
/// phones holding a bootstrap key from an invitation get 10.77.1.x and can
/// reach only the enrollment port. WireGuard's cryptokey routing makes the
/// source address of every tunneled connection authentic: a peer can only
/// send from the addresses the Mac assigned to its key.
public struct OverlayPlan: Sendable, Hashable {
    public var hostAddress = "10.77.0.1"
    /// Raw cmux-tui protocol (JSON lines), spliced to the daemon socket.
    public var daemonPort: UInt16 = 7300
    /// One JSON request and one JSON response per connection.
    public var enrollmentPort: UInt16 = 7301
    /// The UDP port the Mac listens on when it is free.
    public var preferredListenPort: UInt16 = 51888

    public init() {}

    public func deviceAddress(_ index: Int) -> String? {
        (2...254).contains(index) ? "10.77.0.\(index)" : nil
    }

    public func bootstrapAddress(_ index: Int) -> String? {
        (1...254).contains(index) ? "10.77.1.\(index)" : nil
    }

    public func isDeviceAddress(_ address: String) -> Bool {
        guard let last = lastOctet(address, prefix: "10.77.0.") else { return false }
        return (2...254).contains(last)
    }

    public func isBootstrapAddress(_ address: String) -> Bool {
        lastOctet(address, prefix: "10.77.1.") != nil
    }

    private func lastOctet(_ address: String, prefix: String) -> Int? {
        let host = address.split(separator: ":").first.map(String.init) ?? address
        guard host.hasPrefix(prefix), let value = Int(host.dropFirst(prefix.count)) else { return nil }
        return (0...255).contains(value) ? value : nil
    }
}

/// Phone to Mac, over the bootstrap tunnel, on the enrollment port.
public struct EnrollmentRequest: Codable, Hashable, Sendable {
    /// The phone's permanent WireGuard public key.
    public var publicKey: WireGuardKey
    public var deviceName: String
    public var deviceModel: String

    public init(publicKey: WireGuardKey, deviceName: String, deviceModel: String) {
        self.publicKey = publicKey
        self.deviceName = deviceName
        self.deviceModel = deviceModel
    }
}

/// Mac to phone: the permanent peer the Mac added for this phone.
public struct EnrollmentResponse: Codable, Hashable, Sendable {
    public var ok: Bool
    public var error: String?
    /// The phone's permanent tunnel address.
    public var address: String?
    /// The preshared key for the permanent peer.
    public var presharedKey: WireGuardKey?
    /// The device id the Mac filed this phone under (for revocation).
    public var deviceID: String?

    public init(address: String, presharedKey: WireGuardKey, deviceID: String) {
        ok = true
        self.address = address
        self.presharedKey = presharedKey
        self.deviceID = deviceID
    }

    public init(error: String) {
        ok = false
        self.error = error
    }
}

/// A paired Mac as the phone stores it.
public struct PairedHost: Codable, Hashable, Sendable, Identifiable {
    public var id: String { hostID }
    public var hostID: String
    public var hostName: String
    public var hostKey: WireGuardKey
    public var hostAddress: String
    public var endpoints: [String]
    /// The endpoint that last completed a handshake; tried first.
    public var lastGoodEndpoint: String?
    public var address: String
    public var presharedKey: WireGuardKey
    public var deviceID: String
    public var pairedAt: Date

    public init(invitation: PairingInvitation, response: EnrollmentResponse, pairedAt: Date = Date()) throws {
        guard response.ok, let address = response.address, let psk = response.presharedKey,
              let deviceID = response.deviceID else {
            throw PairingError.refused(response.error ?? "Your Mac refused to pair.")
        }
        hostID = invitation.hostID
        hostName = invitation.hostName
        hostKey = invitation.hostKey
        hostAddress = invitation.hostAddress
        endpoints = invitation.endpoints
        self.address = address
        presharedKey = psk
        self.deviceID = deviceID
        self.pairedAt = pairedAt
    }

    /// Endpoints in the order to try: the last one that worked, then the rest.
    public var endpointsToTry: [String] {
        guard let lastGoodEndpoint else { return endpoints }
        return [lastGoodEndpoint] + endpoints.filter { $0 != lastGoodEndpoint }
    }
}

/// One line of JSON (no newline inside), for the enrollment exchange.
public struct JSONLine: Sendable {
    public init() {}

    public func encode(_ value: some Encodable) throws -> Data {
        var data = try JSONEncoder.sorted.encode(value)
        data.append(0x0A)
        return data
    }

    public func decode<T: Decodable>(_ type: T.Type, from line: Data) throws -> T {
        try JSONDecoder().decode(type, from: line)
    }
}
