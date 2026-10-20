import CmuxInstallAuthCore
import Foundation

/// Two independent owners verify the actual signer and session used for each account.
struct MacSignOutOwner: InstallAuthTransport {
    let a = MacTeamAuthOwner(user: "user_a", stackUser: "stack_a", installPrefix: "inst_a_")
    let b = MacTeamAuthOwner(user: "user_b", stackUser: "stack_b", installPrefix: "inst_b_")

    func post(_ path: String, json: Data, bearer: String?, headers: [String: String]) async throws -> (status: Int, body: Data) {
        let body = try JSONSerialization.jsonObject(with: json) as? [String: Any]
        let owner: MacTeamAuthOwner
        if path == "/v1/ops" {
            switch bearer {
            case "session-a": owner = a
            case "session-b": owner = b
            default: throw MacTeamAuthOwner.Failure.invalidRequest
            }
        } else if let install = body?["install"] as? String, install.hasPrefix("inst_a_") {
            owner = a
        } else if let install = body?["install"] as? String, install.hasPrefix("inst_b_") {
            owner = b
        } else { throw MacTeamAuthOwner.Failure.invalidRequest }
        return try await owner.post(path, json: json, bearer: path == "/v1/ops" ? "test-session" : bearer, headers: headers)
    }
}
