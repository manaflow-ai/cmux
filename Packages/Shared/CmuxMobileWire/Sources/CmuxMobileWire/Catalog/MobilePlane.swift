/// Control: Durable Objects over WebSockets. Stream: a CmuxLink session to the Mac.
public enum MobilePlane: String, CaseIterable, Hashable, Sendable, Codable {
    case control, stream
}
