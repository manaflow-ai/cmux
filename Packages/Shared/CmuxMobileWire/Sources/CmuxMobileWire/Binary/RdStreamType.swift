/// cmux.rd/1 stream frame types (cmux-rd-proto `STREAM_*`).
public enum RdStreamType: UInt8, Hashable, Sendable {
    case control = 1
    case datagram = 2
    case bulk = 3
}
