import Foundation
@testable import CmuxMobileShell

struct TestBackupList: Encodable {
    let records: [PairedMacBackupRecord]
    let deletedMacDeviceIDs: [String]
    let revision: Int
    let teamId: String?

    init(
        records: [PairedMacBackupRecord],
        deletedMacDeviceIDs: [String],
        revision: Int = 0,
        teamId: String? = nil
    ) {
        self.records = records
        self.deletedMacDeviceIDs = deletedMacDeviceIDs
        self.revision = revision
        self.teamId = teamId
    }
}
