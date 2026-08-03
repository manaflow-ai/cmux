import Foundation

struct GitHubPullRequestStub: Sendable {
    let expectedURL: URL?
    let statusCode: Int
    let headers: [String: String]
    let data: Data
    let gate: String?

    init(
        expectedURL: URL? = nil,
        statusCode: Int,
        headers: [String: String] = [:],
        data: Data = Data(),
        gate: String? = nil
    ) {
        self.expectedURL = expectedURL
        self.statusCode = statusCode
        self.headers = headers
        self.data = data
        self.gate = gate
    }
}
