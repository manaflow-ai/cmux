public import Foundation

public struct BrowserWebExtensionOperationErrorPayload: Equatable, Sendable {
    public let message: String
    public let method: String
    public let errorDomain: String
    public let errorCode: Int
    public let debugDescription: String?

    public init(
        method: String,
        error: any Error,
        includeDebugDescription: Bool
    ) {
        let nsError = error as NSError
        let description = error.localizedDescription
        self.message = description
        self.method = method
        self.errorDomain = nsError.domain
        self.errorCode = nsError.code
        self.debugDescription = description
    }

    public var foundationData: [String: Any] {
        var data: [String: Any] = [
            "method": method,
            "error": [
                "domain": errorDomain,
                "code": errorCode,
            ],
        ]
        if let debugDescription {
            data["debug_description"] = debugDescription
        }
        return data
    }
}
