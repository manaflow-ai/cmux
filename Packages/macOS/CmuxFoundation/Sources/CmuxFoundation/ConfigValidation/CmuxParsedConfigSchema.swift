import Foundation

/// A deserialized cmux.json schema that validators share instead of re-parsing.
///
/// The tree is never mutated after parsing, so concurrent reads are safe.
struct CmuxParsedConfigSchema: @unchecked Sendable {
    /// The schema embedded in CmuxFoundation, parsed on first use.
    static let embedded = CmuxParsedConfigSchema(data: CmuxEmbeddedConfigSchema.data)

    let root: [String: Any]

    init(data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else {
            preconditionFailure("cmux.json schema is not a JSON object")
        }
        self.root = root
    }
}
