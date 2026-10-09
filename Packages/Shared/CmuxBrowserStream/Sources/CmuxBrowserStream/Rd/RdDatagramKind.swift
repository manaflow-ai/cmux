/// What one `cmux.rd/1` datagram carries (cmux-rd-proto `DatagramKind`).
public enum RdDatagramKind: UInt8, Hashable, Sendable, CaseIterable {
    case video = 1
    case fec = 2
    case audio = 3
    case input = 4
    case inputAck = 5
    case cursorPos = 6
    case feedback = 7
    case probe = 8
    case clockPing = 9
    case clockPong = 10
}
