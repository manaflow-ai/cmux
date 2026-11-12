import Foundation

struct V2KeychainTestKey: Hashable, Sendable {
    let service: String
    let account: String
    let accessGroup: String?
    let dataProtection: Bool
}
