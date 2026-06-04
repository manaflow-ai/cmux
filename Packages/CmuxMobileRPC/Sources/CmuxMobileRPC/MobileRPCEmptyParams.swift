/// Encodes as the empty JSON object `{}` for requests that take no parameters.
///
/// Keeps the wire shape of parameterless requests identical to the legacy
/// `params: [:]` envelopes (the `params` key is always present).
struct MobileRPCEmptyParams: Encodable {}
