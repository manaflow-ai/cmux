import Foundation

/// A syntactically valid device UUID normalized for identity comparisons.
struct CmxIrohDeviceID: Equatable, Sendable {
    let value: String

    init?(_ rawValue: String) {
        guard let uuid = UUID(uuidString: rawValue) else { return nil }
        let canonical = uuid.uuidString.lowercased()
        guard rawValue.lowercased() == canonical else { return nil }
        value = canonical
    }
}
