/// A refused record; the session closes the channel (or the carrier) with `proto.bad_record`.
public struct RecordError: Error, Hashable, Sendable {
    public static let code = "proto.bad_record"

    public var reason: RecordErrorReason
    public var message: String

    public init(_ reason: RecordErrorReason, _ message: String) {
        self.reason = reason
        self.message = message
    }
}
