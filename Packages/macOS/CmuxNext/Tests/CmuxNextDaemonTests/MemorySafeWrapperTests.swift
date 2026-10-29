import Darwin
import Foundation
import Testing
@testable import CmuxNextDaemon

/// The safe surfaces that took the Daemon, Control and Mobile modules' repeated pointer code
/// (strict memory safety): one `sockaddr_un` filler (Chromium's `FillUnixAddress`), `strerror_r` text (Chromium's
/// `safe_strerror`), and key bytes drawn without lending a pointer.
@Suite struct MemorySafeWrapperTests {
    @Test func errorTextMatchesStrerrorForKnownAndUnknownCodes() {
        #expect(POSIXErrorText(ENOENT).description == "No such file or directory")
        #expect(POSIXErrorText(EPIPE).description == "Broken pipe")
        // Darwin names an unknown code instead of failing; the text is never empty.
        #expect(POSIXErrorText(9_999).description.contains("9999"))
        #expect("\(POSIXErrorText(ECONNREFUSED))" == "Connection refused")
    }

    @Test func socketAddressRefusesAPathThatDoesNotFitSunPath() {
        #expect(UnixSocketAddress.pathCapacity == 104)
        let longest = "/" + String(repeating: "a", count: UnixSocketAddress.pathCapacity - 2)
        #expect(UnixSocketAddress(path: longest) != nil)
        #expect(UnixSocketAddress(path: longest + "a") == nil)
    }

    @Test func socketAddressBindsAndConnects() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "usa-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "s").path
        let address = try #require(UnixSocketAddress(path: path))
        #expect(address.path == path)

        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(listener >= 0)
        defer { close(listener) }
        #expect(address.bind(listener) == 0)
        #expect(listen(listener, 1) == 0)

        let client = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(client >= 0)
        defer { close(client) }
        var on: Int32 = 1
        // SAFETY: setsockopt reads MemoryLayout<Int32>.size bytes from `on`, a local Int32.
        _ = unsafe setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        #expect(address.connect(client) == 0)

        // A second bind at the same path fails with EADDRINUSE, as bind(2) does.
        let other = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(other >= 0)
        defer { close(other) }
        let bound = address.bind(other)
        let code = errno
        #expect(bound == -1)
        #expect(code == EADDRINUSE)
    }

    @Test func connectToAMissingPathFails() throws {
        let address = try #require(UnixSocketAddress(path: "/tmp/cmux-missing-\(UUID().uuidString.prefix(8))"))
        let client = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(client >= 0)
        defer { close(client) }
        let connected = address.connect(client)
        let code = errno
        #expect(connected == -1)
        #expect(code == ENOENT)
    }

    @Test func generatedInstallKeysAreFreshAndWellFormed() {
        let first = FrontendInstallKey.generate()
        let second = FrontendInstallKey.generate()
        #expect(first.key.count == 32)
        #expect(first.installID.hasPrefix("inst_"))
        #expect(first.installID.count == "inst_".count + 20)
        #expect(first.key != second.key)
        #expect(first.installID != second.installID)
    }
}
