import Foundation

struct CmuxRunWorkingDirectoryIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64

    var shellToken: String {
        "\(device):\(inode)"
    }
}
