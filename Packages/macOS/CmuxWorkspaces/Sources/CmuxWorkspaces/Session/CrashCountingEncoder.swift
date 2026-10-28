import Foundation

/// Preflights Codable's nested containers without storing their contents.
struct CrashCountingEncoder: Encoder {
    let budget: CrashEncodingBudget
    var codingPath: [any CodingKey] = []
    var userInfo: [CodingUserInfoKey: Any] { [:] }
    var depth = 0

    func encode<Value: Encodable>(_ value: Value) throws {
        try budget.checkDepth(depth)
        try budget.charge(bytes: 0, nodes: 1)
        // JSONEncoder gives Data a base64 representation; do not traverse one
        // encoding container per byte or allocate the base64 during preflight.
        if let data = value as? Data {
            guard data.count <= budget.remainingBytes else { throw CrashEncodingBudget.Failure.exhausted }
            let (rounded, overflow) = data.count.addingReportingOverflow(2)
            // Base64 '/' characters can be escaped by JSONEncoder, so reserve
            // two JSON bytes for each of the four characters per group.
            guard !overflow, rounded / 3 <= (budget.remainingBytes - min(2, budget.remainingBytes)) / 8 else {
                throw CrashEncodingBudget.Failure.exhausted
            }
            try budget.charge(bytes: (rounded / 3) * 8 + 2)
        } else if let date = value as? Date {
            guard date.timeIntervalSinceReferenceDate.isFinite else { throw CrashEncodingBudget.Failure.invalidValue }
            try budget.charge(bytes: 32)
        } else if let url = value as? URL {
            try budget.string(url.absoluteString)
        } else {
            try value.encode(to: self)
        }
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        openContainer()
        return KeyedEncodingContainer(CrashKeyedEncodingContainer<Key>(encoder: self))
    }
    func unkeyedContainer() -> any UnkeyedEncodingContainer {
        openContainer()
        return CrashUnkeyedEncodingContainer(encoder: self)
    }
    func singleValueContainer() -> any SingleValueEncodingContainer {
        CrashSingleValueEncodingContainer(encoder: self)
    }
    func child(_ key: any CodingKey) -> Self {
        Self(budget: budget, codingPath: codingPath + [key], depth: depth + 1)
    }
    private func openContainer() {
        do { try budget.checkDepth(depth); try budget.charge(bytes: 2, nodes: 1) }
        catch { budget.fail() }
    }
}
