import Foundation

protocol MobileAttachTokenSecretStoring: Sendable {
    func readAttachToken(account: String) -> String?
    func saveAttachToken(_ token: String, account: String) -> Bool
    func deleteAttachToken(account: String)
}
