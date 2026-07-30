import Foundation
@testable import CmuxMobileShell

struct TestBackupList: Encodable {
    let records: [PairedMacBackupRecord]
    let deletedMacDeviceIDs: [String]
}
