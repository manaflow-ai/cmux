import Foundation

struct CmuxRunWorkingDirectoryCommand: Sendable {
    let executableURL: URL
    let arguments: [String]
}

struct CmuxRunWorkingDirectoryIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64

    var shellToken: String {
        "\(device):\(inode)"
    }
}

struct CmuxRunResolvedWorkingDirectory: Equatable, Sendable {
    let path: String
    let identity: CmuxRunWorkingDirectoryIdentity
}
