import Darwin
import Foundation
import Testing
@testable import CmuxNextComputerUse

struct ComputerUseHelperV2PeerTests {
    @Test func daemonRegistrationRejectsAConnectedPeerOutsideTheAppsTeam() async throws {
        let socketPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-cua-peer-\(UUID().uuidString.prefix(8)).sock").path
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(listener >= 0)
        defer {
            close(listener)
            unlink(socketPath)
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        try #require(socketPath.utf8.count < MemoryLayout.size(ofValue: address.sun_path))
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: socketPath.utf8)
            buffer[socketPath.utf8.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        try #require(bound == 0)
        try #require(Darwin.listen(listener, 1) == 0)

        var executablePath = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        try #require(proc_pidpath(getpid(), &executablePath, UInt32(executablePath.count)) > 0)
        let pathBytes = executablePath.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let executable = URL(fileURLWithPath: String(decoding: pathBytes, as: UTF8.self))

        let pathMatch = await ComputerUseHelperV2.daemonStamp(
            socketPath: socketPath, executable: executable, teamIdentifier: nil
        )
        #expect(pathMatch?.pid == getpid())
        let accepted = Darwin.accept(listener, nil, nil)
        try #require(accepted >= 0)
        close(accepted)

        let wrongTeam = await ComputerUseHelperV2.daemonStamp(
            socketPath: socketPath, executable: executable, teamIdentifier: "NOTCMUXTEAM"
        )
        #expect(wrongTeam == nil)
    }
}
