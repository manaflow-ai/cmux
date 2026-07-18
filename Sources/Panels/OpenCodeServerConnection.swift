import Foundation

struct OpenCodeServerConnection: Equatable, Sendable {
    let baseURL: URL
    let authorizationHeader: String
    let processIdentifier: Int32
}
