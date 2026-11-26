import Foundation

struct OpenCodeServerAuth: Equatable {
    let authorizationHeader: String

    init?(environment: [String: String]) {
        guard let password = environment["OPENCODE_SERVER_PASSWORD"],
              !password.isEmpty else {
            return nil
        }
        let username = environment["OPENCODE_SERVER_USERNAME"].flatMap { value -> String? in
            value.isEmpty ? nil : value
        } ?? "opencode"
        let token = "\(username):\(password)"
        authorizationHeader = "Basic \(Data(token.utf8).base64EncodedString())"
    }
}
