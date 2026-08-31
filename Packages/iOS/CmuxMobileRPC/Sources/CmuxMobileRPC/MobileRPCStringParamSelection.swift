/// The normalized selection of one or more synonymous RPC identifier fields.
///
/// The value is `nil` when no non-empty field was present. A conflict means
/// that two aliases carried different non-empty values and the request must
/// not be treated as attach-ticket-covered.
struct MobileRPCStringParamSelection: Sendable {
    let value: String?
    let hasConflict: Bool
}
