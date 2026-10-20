import Foundation

/// Requires a daemon that forwards restrictive account/team context; older daemons refuse the command.
public struct AppsScopedRunRequest: DaemonRequest, VerbatimFieldsRequest {
    public typealias Response = AppsRunResult
    public static let command = "apps-run-scoped"
    public let request: AppsRunRequest
    public let expectedScope: String

    public init(_ request: AppsRunRequest, expectedScope: String) {
        self.request = request; self.expectedScope = expectedScope
    }
    public func encode(to encoder: any Encoder) throws {
        try request.encode(to: encoder)
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(expectedScope, forKey: .expectedScope)
    }
    private enum CodingKeys: String, CodingKey { case expectedScope }
    var verbatimFields: [String: JSONValue] { request.verbatimFields }
}
