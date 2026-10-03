import Foundation

/// The result of a conditional GitHub request.
public nonisolated struct GitHubAPIResponse<Value: Sendable>: Sendable {
    public var value: Value?
    public var etag: String?
    public var notModified: Bool

    public init(value: Value?, etag: String? = nil, notModified: Bool = false) {
        self.value = value
        self.etag = etag
        self.notModified = notModified
    }
}
