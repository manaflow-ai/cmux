import Foundation
@testable import CmuxMobileShell

struct TestBackupList: Encodable {
    let records: [PairedMacBackupRecord]
    let deletedMacDeviceIDs: [String]
    let revision: Int

    init(
        records: [PairedMacBackupRecord],
        deletedMacDeviceIDs: [String],
        revision: Int = 0
    ) {
        self.records = records
        self.deletedMacDeviceIDs = deletedMacDeviceIDs
        self.revision = revision
    }
}
