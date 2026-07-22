import Foundation

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
        self.message = String(
            localized: "cli.browser.extensions.error.operationFailed",
            defaultValue: "Extension operation failed"
        )
        self.method = method
        self.errorDomain = nsError.domain
        self.errorCode = nsError.code
        self.debugDescription = includeDebugDescription ? error.localizedDescription : nil
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
