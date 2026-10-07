/// A UDP datagram inside the tunnel: IPv6 header, UDP header with the
/// mandatory IPv6 checksum, payload. Plaintext of a WireGuard data packet
/// must be an IP packet for a boringtun / `cmux-wg` peer to accept it; lane
/// frames ride overlay UDP to the `link-lanes` port.
struct OverlayDatagram: Equatable {
    static let headerLength = 48
    /// The `link-lanes` service port inside the session (transport.md 12a
    /// registers 4100 to 4103; this lane adds 4104).
    static let laneServicePort: UInt16 = 4104
    private static let nextHeaderUDP: UInt8 = 17
    private static let hopLimit: UInt8 = 64

    var source: OverlayAddress
    var destination: OverlayAddress
    var sourcePort: UInt16 = laneServicePort
    var destinationPort: UInt16 = laneServicePort
    var payload: [UInt8]

    func encode() -> [UInt8] {
        let udpLength = UInt16(8 + payload.count)
        var packet: [UInt8] = [0x60, 0, 0, 0]
        packet += Self.be16(udpLength) + [Self.nextHeaderUDP, Self.hopLimit]
        packet += [UInt8](source.bytes) + [UInt8](destination.bytes)
        packet += Self.be16(sourcePort) + Self.be16(destinationPort) + Self.be16(udpLength) + [0, 0]
        packet += payload
        var checksum = Self.checksum(packet: packet, udpLength: udpLength)
        if checksum == 0 { checksum = 0xFFFF }
        packet[46] = UInt8(checksum >> 8)
        packet[47] = UInt8(checksum & 0xFF)
        return packet
    }

    /// Parses a decrypted packet, ignoring WireGuard's zero padding after the
    /// IPv6 payload length. Nil for anything that is not a well-formed,
    /// checksummed IPv6 UDP datagram.
    static func decode(_ packet: [UInt8]) -> OverlayDatagram? {
        guard packet.count >= headerLength, packet[0] >> 4 == 6, packet[6] == nextHeaderUDP else { return nil }
        let payloadLength = Int(be16(packet, 4))
        guard payloadLength >= 8, packet.count >= 40 + payloadLength, Int(be16(packet, 44)) == payloadLength else { return nil }
        let trimmed = Array(packet[..<(40 + payloadLength)])
        guard checksum(packet: trimmed, udpLength: UInt16(payloadLength)) == 0,
              let source = OverlayAddress(bytes: trimmed[8..<24]),
              let destination = OverlayAddress(bytes: trimmed[24..<40])
        else { return nil }
        return OverlayDatagram(
            source: source, destination: destination,
            sourcePort: be16(trimmed, 40), destinationPort: be16(trimmed, 42),
            payload: Array(trimmed[48...])
        )
    }

    /// Ones' complement sum over the IPv6 pseudo-header and the UDP datagram.
    /// Zero when a packet carrying a valid checksum is summed.
    private static func checksum(packet: [UInt8], udpLength: UInt16) -> UInt16 {
        var sum: UInt32 = 0
        func add(_ bytes: ArraySlice<UInt8>) {
            var index = bytes.startIndex
            while index + 1 < bytes.endIndex {
                sum &+= UInt32(bytes[index]) << 8 | UInt32(bytes[index + 1])
                index += 2
            }
            if index < bytes.endIndex { sum &+= UInt32(bytes[index]) << 8 }
        }
        add(packet[8..<40])
        sum &+= UInt32(udpLength)
        sum &+= UInt32(nextHeaderUDP)
        add(packet[40...])
        while sum >> 16 != 0 { sum = (sum & 0xFFFF) &+ (sum >> 16) }
        return ~UInt16(sum)
    }

    private static func be16(_ value: UInt16) -> [UInt8] { [UInt8(value >> 8), UInt8(value & 0xFF)] }

    private static func be16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }
}
