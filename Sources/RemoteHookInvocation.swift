import Foundation

struct RemoteHookInvocation: Sendable {
    let arguments: [String]
    let environment: [String: String]
    let input: Data
}
