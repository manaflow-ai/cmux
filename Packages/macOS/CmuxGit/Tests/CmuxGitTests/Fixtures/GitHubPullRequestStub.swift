import Foundation

struct GitHubPullRequestStub: Sendable {
    let statusCode: Int
    let headers: [String: String]
    let data: Data
    let gate: String?

    init(
        statusCode: Int,
        headers: [String: String] = [:],
        data: Data = Data(),
        gate: String? = nil
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.data = data
        self.gate = gate
    }
}
