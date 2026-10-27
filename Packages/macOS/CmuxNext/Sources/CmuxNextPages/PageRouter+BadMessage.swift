import CmuxNextSettings

/// The page's malformed messages: envelopes the router refuses (no `t`, an unknown `t`, a call without an `op`
/// or with a bad `opid`, a sub without a `stream`, an `id` or `sub` that no counter reaches) and bodies the
/// bridge drops before it. Each gets its error reply (or none), is counted in ``PageRouter/badMessages``, and
/// the page goes on, as Chrome counts each bad IPC message (`bad_message::ReceivedBadMessage`,
/// content/browser/bad_message.cc).
extension PageRouter {
    /// Counts one malformed envelope and returns its reply.
    func badMessage(_ reply: JSONValue) -> JSONValue {
        badMessages += 1
        return reply
    }

    /// A message body from the page's bridge, as the engine handed it, read as JSON; nil (counted) for one no
    /// JSON holds (a `Date`, `Data`, a dictionary with a key that is no string). Two keys that are equal Swift
    /// strings read as one member.
    func envelope(_ body: Any) -> JSONValue? {
        guard let value = JSONValue(foundation: body) else {
            badMessages += 1
            return nil
        }
        return value
    }

    /// The counter an envelope's `id` or `sub` names: 0 when it is absent or not a number, else the number's
    /// whole part from 0 (for a negative number) to 2^53, JavaScript's largest exact integer. Nil for a number
    /// past that or not finite: no counter reaches it, and `UInt64(_:)` traps on one past 2^64.
    static func counter(_ value: JSONValue?) -> UInt64? {
        guard let number = value?.doubleValue else { return 0 }
        guard number.isFinite, number <= 9_007_199_254_740_992 else { return nil }
        return UInt64(max(0, number))
    }

    static func error(id: UInt64, _ error: PageError) -> JSONValue {
        var envelope: [String: JSONValue] = [
            "t": "err", "id": .number(Double(id)), "code": .string(error.code), "message": .string(error.message),
            "retryable": .bool(error.retryable),
        ]
        if let details = error.details { envelope["details"] = details }
        return .object(envelope)
    }
}

nonisolated extension PageError {
    /// An envelope's `id` or `sub` (`field`) that no counter reaches.
    static func badCounter(_ field: String) -> PageError {
        PageError(code: "cmux.protocol.bad_message", message: "\(field) must be a number from 0 to 2^53")
    }
}
