import Foundation

extension MobilePairedMacStore {
    static func attachTokenKeychainService(bundleIdentifier: String?) -> String {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else {
            return "com.cmuxterm.app.mobile-attach-token"
        }
        return "\(bundleIdentifier).mobile-attach-token"
    }

    func attachTokenSecretAccount(macDeviceID: String, ownerKey: String) -> String {
        let payload = "\(ownerKey)\u{1E}\(macDeviceID)"
        let encoded = Data(payload.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "paired-mac-attach-token-v1:\(encoded)"
    }

    func attachTokenSecret(for row: MobilePairedMacStoreMacRow) async -> String? {
        guard row.attachTokenExpiresAt != nil else { return nil }
        let account = attachTokenSecretAccount(macDeviceID: row.macDeviceID, ownerKey: row.ownerKey)
        return await attachTokenSecrets.readAttachToken(account: account)
    }

    func saveAttachTokenSecret(
        _ token: String,
        macDeviceID: String,
        ownerKey: String
    ) async -> Bool {
        let account = attachTokenSecretAccount(macDeviceID: macDeviceID, ownerKey: ownerKey)
        return await attachTokenSecrets.saveAttachToken(token, account: account)
    }

    @discardableResult
    func copyAttachTokenSecret(
        macDeviceID: String,
        fromOwnerKey: String,
        toOwnerKey: String
    ) async -> Bool {
        guard fromOwnerKey != toOwnerKey else { return false }
        let source = attachTokenSecretAccount(macDeviceID: macDeviceID, ownerKey: fromOwnerKey)
        guard let token = await attachTokenSecrets.readAttachToken(account: source) else { return false }
        let destination = attachTokenSecretAccount(macDeviceID: macDeviceID, ownerKey: toOwnerKey)
        return await attachTokenSecrets.saveAttachToken(token, account: destination)
    }

    func deleteAttachTokenSecret(macDeviceID: String, ownerKey: String) async {
        let account = attachTokenSecretAccount(macDeviceID: macDeviceID, ownerKey: ownerKey)
        await attachTokenSecrets.deleteAttachToken(account: account)
    }

    func deleteAttachTokenSecrets(for rows: [MobilePairedMacStoreMacRow]) async {
        for row in rows {
            await deleteAttachTokenSecret(macDeviceID: row.macDeviceID, ownerKey: row.ownerKey)
        }
    }
}
