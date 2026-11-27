public import Foundation

/// Fixed policies (tests, previews).
public nonisolated struct FixedChromePolicyReader: ChromePolicyReading {
    public let document: ChromePolicyDocument

    public init(_ document: ChromePolicyDocument) {
        self.document = document
    }

    public func read() -> ChromePolicyDocument { document }
}
