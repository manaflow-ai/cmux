import Foundation

struct PairedMacBackupMigrationScope {
    let currentScope: String?
    let legacyScope: String?
    let teamID: String?
    let expectedUserID: String?

    var key: String? {
        guard let expectedUserID, !expectedUserID.isEmpty else { return nil }
        let identity = [
            currentScope ?? "<unscoped>",
            legacyScope ?? "<unscoped>",
            teamID ?? "<personal>",
            expectedUserID,
        ].joined(separator: "\u{0}")
        let encoded = Data(identity.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "cmux.pairedMacBackup.legacyMigration.v2.\(encoded)"
    }
}
