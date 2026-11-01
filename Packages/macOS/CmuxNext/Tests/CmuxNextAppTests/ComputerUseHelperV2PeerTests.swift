import Darwin
import Foundation
import Testing
@testable import CmuxNextComputerUse

struct ComputerUseHelperV2PeerTests {
    @Test func helperLaunchScopeContainsOnlyItsOwnTaggedDevBundle() {
        let own = "com.cmuxterm.app.debug.guard-test"
        let environment = ComputerUseHelperV2.environment(bundleID: own)
        #expect(environment["CMUX_CUA_ALLOWED_TARGET_BUNDLE_IDS"] == own)
        for bundleID in [nil, "com.cmuxterm.app", "com.cmuxterm.app.nightly",
                         "com.cmuxterm.app.debug", "com.cmuxterm.app.debug.", "com.apple.Terminal"] {
            #expect(ComputerUseHelperV2.environment(bundleID: bundleID)["CMUX_CUA_ALLOWED_TARGET_BUNDLE_IDS"] == "")
        }
    }

    @Test func signedAdmissionUsesALiveTeamRequirementInsteadOfAPathHash() {
        let executable = URL(fileURLWithPath: "/mutable/acpmux")
        let signed = ComputerUseHelperV2.acpmuxAdmission(
            executable: executable, teamIdentifier: "TEAM123", identifier: { _ in "cmux-cli" },
            hash: { _ in Data([1, 2, 3]) }
        )
        #expect(signed.hashes.isEmpty)
        #expect(signed.requirement == "identifier \"cmux-cli\" and anchor apple generic and certificate leaf[subject.OU] = \"TEAM123\"")

        let development = ComputerUseHelperV2.acpmuxAdmission(
            executable: executable, teamIdentifier: nil, identifier: { _ in nil }, hash: { _ in Data([1, 2, 3]) }
        )
        #expect(development.hashes == ["010203"])
        #expect(development.requirement == nil)
    }

    @Test func configureLineGivesTheHelperTheAcpmuxAdmissionOfThisAppsAcpmux() throws {
        let object = { (line: Data) throws -> [String: Any] in
            #expect(line.last == UInt8(ascii: "\n"))
            return try #require(try JSONSerialization.jsonObject(with: line) as? [String: Any])
        }
        let acpmux = URL(fileURLWithPath: "/app/acpmux")
        var asked: [URL] = []
        let signed = try object(ComputerUseHelperV2.configureLine(
            socket: "/run/helper.sock", hostSocket: "/run/host.sock", hostSecret: Data([0xab, 0x01]),
            secret: Data([0x0f]), acpmuxExecutable: acpmux,
            admit: { asked.append($0); return ([], "identifier \"cmux\" and anchor apple generic") }
        ))
        #expect(asked == [acpmux])
        #expect(signed["type"] as? String == "configure")
        #expect(signed["socket"] as? String == "/run/helper.sock")
        #expect(signed["host_socket"] as? String == "/run/host.sock")
        #expect(signed["host_secret"] as? String == "ab01")
        #expect(signed["secret"] as? String == "0f")
        #expect(signed["acpmux_cdhashes"] as? [String] == [])
        #expect(signed["acpmux_requirement"] as? String == "identifier \"cmux\" and anchor apple generic")

        let development = try object(ComputerUseHelperV2.configureLine(
            socket: "/s", hostSocket: "/h", hostSecret: Data(), secret: Data(), acpmuxExecutable: acpmux,
            admit: { _ in (["0102"], nil) }
        ))
        #expect(development["acpmux_cdhashes"] as? [String] == ["0102"])
        #expect(development["acpmux_requirement"] is NSNull)

        // No acpmux: no bridge is admitted by code identity, and nothing is asked.
        asked = []
        let none = try object(ComputerUseHelperV2.configureLine(
            socket: "/s", hostSocket: "/h", hostSecret: Data(), secret: Data(), acpmuxExecutable: nil,
            admit: { asked.append($0); return (["ff"], "x") }
        ))
        #expect(asked.isEmpty)
        #expect(none["acpmux_cdhashes"] as? [String] == [])
        #expect(none["acpmux_requirement"] is NSNull)

        // By default the admission is acpmuxAdmission's, with this app's team.
        let me = URL(fileURLWithPath: CommandLine.arguments[0])
        let byDefault = try object(ComputerUseHelperV2.configureLine(
            socket: "/s", hostSocket: "/h", hostSecret: Data(), secret: Data(), acpmuxExecutable: me
        ))
        let expected = ComputerUseHelperV2.acpmuxAdmission(executable: me)
        #expect(byDefault["acpmux_cdhashes"] as? [String] == expected.hashes)
        #expect(byDefault["acpmux_requirement"] as? String == expected.requirement)
    }

    @Test func registerLineNamesTheDaemonByPidAndStartTime() throws {
        let line = ComputerUseHelperV2.registerLine((pid: 4242, startSeconds: 1_700_000_000, startMicroseconds: 17))
        let object = try #require(try JSONSerialization.jsonObject(with: line) as? [String: Any])
        #expect(object["type"] as? String == "register_acpmux")
        #expect(object["pid"] as? Int == 4242)
        #expect(object["start_sec"] as? Int == 1_700_000_000)
        #expect(object["start_usec"] as? Int == 17)
    }

    @Test func daemonRegistrationTakesASameUserPeerAtTheAcpmuxPathOnly() async throws {
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

        let pathMatch = await ComputerUseHelperV2.daemonStamp(socketPath: socketPath, executable: executable)
        #expect(pathMatch?.pid == getpid())
        let accepted = Darwin.accept(listener, nil, nil)
        try #require(accepted >= 0)
        close(accepted)

        let otherPath = await ComputerUseHelperV2.daemonStamp(
            socketPath: socketPath, executable: URL(fileURLWithPath: "/not-the-peer")
        )
        #expect(otherPath == nil)
    }
}
