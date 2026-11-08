import Darwin
import Foundation
import Testing
@testable import CmuxFoundation

struct SSHPTYAdmissionAndModeTests {
    @Test(arguments: [false, true])
    func releaseIdentityAndDevelopmentSuffix(allowDevelopment: Bool) {
        let policy = SSHPTYDaemonCompatibility(clientVersion: "1.2.3", allowsDevelopmentFingerprint: allowDevelopment)
        #expect(policy.matches("1.2.3"))
        #expect(policy.matches("1.2.3-dev-012345abcdef") == allowDevelopment)
        for version in [nil, "", "1.2.2", "1.2.3-incompatible", "1.2.3-dev-012345abcdeg"] {
            #expect(!policy.matches(version))
        }
    }

    @Test
    func terminalOwnerTransitionsAndRestoresOriginalFlags() throws {
        var master: Int32 = -1
        var slave: Int32 = -1
        try #require(openpty(&master, &slave, nil, nil, nil) == 0)
        defer { Darwin.close(master); Darwin.close(slave) }
        var original = termios()
        try #require(tcgetattr(slave, &original) == 0)
        original.c_iflag |= tcflag_t(IXOFF)
        try #require(tcsetattr(slave, TCSANOW, &original) == 0)
        try #require(tcgetattr(slave, &original) == 0)
        let owner = try #require(SSHPTYTerminalInputMode(fileDescriptor: slave))
        #expect(owner.beginDisconnected())
        var current = termios()
        try #require(tcgetattr(slave, &current) == 0)
        #expect(current.c_lflag & tcflag_t(ECHO | ICANON) == 0)
        #expect(current.c_lflag & tcflag_t(ISIG) != 0)
        #expect(owner.beginForwarding())
        #expect(owner.beginForwarding())
        try #require(tcgetattr(slave, &current) == 0)
        #expect(current.c_lflag & tcflag_t(ECHO | ICANON | ISIG) == 0)
        #expect(owner.restore(flushInput: true))
        try #require(tcgetattr(slave, &current) == 0)
        #expect(current.c_iflag == original.c_iflag)
        #expect(current.c_oflag == original.c_oflag)
        #expect(current.c_cflag == original.c_cflag)
        #expect(current.c_lflag == original.c_lflag)
        #expect(withUnsafeBytes(of: current.c_cc) { Array($0) } == withUnsafeBytes(of: original.c_cc) { Array($0) })
        #expect(!owner.beginForwarding())
    }

    @Test
    func unchangedModeCanDiscardDetachedInputWithoutChangingFlags() throws {
        var master: Int32 = -1
        var slave: Int32 = -1
        try #require(openpty(&master, &slave, nil, nil, nil) == 0)
        defer { Darwin.close(master); Darwin.close(slave) }
        let owner = try #require(SSHPTYTerminalInputMode(fileDescriptor: slave))
        let input = Array("queued-command\n".utf8)
        try #require(input.withUnsafeBytes { Darwin.write(master, $0.baseAddress!, $0.count) } == input.count)
        var readable = pollfd(fd: slave, events: Int16(POLLIN), revents: 0)
        try #require(Darwin.poll(&readable, 1, 5_000) == 1)
        #expect(owner.restore(flushInput: true))
        _ = fcntl(slave, F_SETFL, O_NONBLOCK)
        var byte: UInt8 = 0
        let readResult = Darwin.read(slave, &byte, 1)
        let readErrno = errno
        #expect(readResult == -1)
        #expect(readErrno == EAGAIN)
    }
}
