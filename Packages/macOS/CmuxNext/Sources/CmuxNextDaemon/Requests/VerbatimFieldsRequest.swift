/// A request with fields whose JSON goes on the wire byte for byte (an
/// app's own args). The request's `encode` leaves them out.
protocol VerbatimFieldsRequest {
    var verbatimFields: [String: JSONValue] { get }
}
