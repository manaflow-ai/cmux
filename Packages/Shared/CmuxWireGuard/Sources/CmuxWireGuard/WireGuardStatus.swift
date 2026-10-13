public import Foundation
public import CmuxWireGuardPairing

/// A parsed UAPI `get` dump.
public struct WireGuardStatus: Sendable, Hashable {
    public struct PeerStatus: Sendable, Hashable {
        public var publicKey: WireGuardKey
        public var endpoint: String?
        public var lastHandshake: Date?
        public var receivedBytes: UInt64 = 0
        public var sentBytes: UInt64 = 0
    }

    public var listenPort: UInt16?
    public var peers: [PeerStatus] = []

    public init(uapi: String) {
        var current: PeerStatus?
        var handshakeSeconds: Int64 = 0
        func flush() {
            guard var peer = current else { return }
            if handshakeSeconds > 0 { peer.lastHandshake = Date(timeIntervalSince1970: TimeInterval(handshakeSeconds)) }
            peers.append(peer)
            current = nil
            handshakeSeconds = 0
        }
        for line in uapi.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq]
            let value = String(line[line.index(after: eq)...])
            switch key {
            case "listen_port": listenPort = UInt16(value)
            case "public_key":
                flush()
                if let raw = Data(hexString: value), let key = WireGuardKey(rawValue: raw) {
                    current = PeerStatus(publicKey: key)
                }
            case "endpoint": current?.endpoint = value
            case "last_handshake_time_sec": handshakeSeconds = Int64(value) ?? 0
            case "rx_bytes": current?.receivedBytes = UInt64(value) ?? 0
            case "tx_bytes": current?.sentBytes = UInt64(value) ?? 0
            default: break
            }
        }
        flush()
    }

    public func peer(_ key: WireGuardKey) -> PeerStatus? {
        peers.first { $0.publicKey == key }
    }
}

extension Data {
    init?(hexString: String) {
        guard hexString.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
