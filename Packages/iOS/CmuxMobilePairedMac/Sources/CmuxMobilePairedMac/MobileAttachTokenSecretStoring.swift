import Foundation

protocol MobileAttachTokenSecretStoring: Sendable {
    func readAttachToken(account: String) async -> String?
    func saveAttachToken(_ token: String, account: String) async -> Bool
    func deleteAttachToken(account: String) async
}
