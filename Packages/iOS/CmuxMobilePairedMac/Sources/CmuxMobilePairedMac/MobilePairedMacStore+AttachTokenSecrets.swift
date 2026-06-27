import Foundation

extension MobilePairedMacStore {
    func attachTokenSecretAccount(macDeviceID: String, ownerKey: String) -> String {
        let payload = "\(ownerKey)\u{1E}\(macDeviceID)"
        let encoded = Data(payload.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "paired-mac-attach-token-v1:\(encoded)"
    }

    func attachTokenSecret(for row: MobilePairedMacStoreMacRow) -> String? {
        guard row.attachTokenExpiresAt != nil else { return nil }
        let account = attachTokenSecretAccount(macDeviceID: row.macDeviceID, ownerKey: row.ownerKey)
        return attachTokenSecrets.readAttachToken(account: account)
    }

    func saveAttachTokenSecret(
        _ token: String,
        macDeviceID: String,
        ownerKey: String
    ) -> Bool {
        let account = attachTokenSecretAccount(macDeviceID: macDeviceID, ownerKey: ownerKey)
        return attachTokenSecrets.saveAttachToken(token, account: account)
    }

    @discardableResult
    func copyAttachTokenSecret(
        macDeviceID: String,
        fromOwnerKey: String,
        toOwnerKey: String
    ) -> Bool {
        guard fromOwnerKey != toOwnerKey else { return false }
        let source = attachTokenSecretAccount(macDeviceID: macDeviceID, ownerKey: fromOwnerKey)
        guard let token = attachTokenSecrets.readAttachToken(account: source) else { return false }
        let destination = attachTokenSecretAccount(macDeviceID: macDeviceID, ownerKey: toOwnerKey)
        return attachTokenSecrets.saveAttachToken(token, account: destination)
    }

    func deleteAttachTokenSecret(macDeviceID: String, ownerKey: String) {
        let account = attachTokenSecretAccount(macDeviceID: macDeviceID, ownerKey: ownerKey)
        attachTokenSecrets.deleteAttachToken(account: account)
    }

    func deleteAttachTokenSecrets(for rows: [MobilePairedMacStoreMacRow]) {
        for row in rows {
            deleteAttachTokenSecret(macDeviceID: row.macDeviceID, ownerKey: row.ownerKey)
        }
    }
}
