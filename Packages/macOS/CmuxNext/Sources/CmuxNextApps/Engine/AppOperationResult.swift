/// A successful op: `{value, revision?, transaction?, replayed?}`.
public nonisolated struct AppOperationResult: Sendable, Hashable {
    public var value: AppJSON
    public var revision: String?
    public var transaction: String?
    public var replayed: Bool?

    public init(value: AppJSON, revision: String? = nil, transaction: String? = nil, replayed: Bool? = nil) {
        self.value = value
        self.revision = revision
        self.transaction = transaction
        self.replayed = replayed
    }

    var json: AppJSON {
        var object: [String: AppJSON] = ["value": value]
        if let revision { object["revision"] = .string(revision) }
        if let transaction { object["transaction"] = .string(transaction) }
        if let replayed { object["replayed"] = .bool(replayed) }
        return .object(object)
    }
}

/// A failed op: `{code, message, details?, retryable}` (spec 6.2).
public nonisolated struct AppOperationError: Error, Sendable, Hashable {
    public var code: String
    public var message: String
    public var details: AppJSON?
    public var retryable: Bool

    public init(code: String, message: String, details: AppJSON? = nil, retryable: Bool = false) {
        self.code = code
        self.message = message
        self.details = details
        self.retryable = retryable
    }

    public static func unsupported(_ op: String) -> AppOperationError {
        AppOperationError(code: "operation.unsupported", message: "\(op) is not supported by this host yet", details: ["op": .string(op)])
    }

    var json: AppJSON {
        var object: [String: AppJSON] = ["code": .string(code), "message": .string(message), "retryable": .bool(retryable)]
        if let details { object["details"] = details }
        return .object(object)
    }
}
