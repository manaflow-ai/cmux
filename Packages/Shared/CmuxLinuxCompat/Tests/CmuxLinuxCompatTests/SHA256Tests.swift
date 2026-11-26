#if !canImport(CryptoKit)
import CmuxLinuxCompat
import Foundation
import XCTest

final class SHA256Tests: XCTestCase {
    private func hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func testFIPS180Vectors() {
        XCTAssertEqual(hex(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(hex("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(
            hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        )
        XCTAssertEqual(
            hex(String(repeating: "a", count: 1_000_000)),
            "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"
        )
    }

    func testDarwinForwardersReachLibc() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(Darwin.pipe(&fds), 0)
        XCTAssertEqual(Darwin.write(fds[1], "ok", 2), 2)
        var buffer = [UInt8](repeating: 0, count: 2)
        XCTAssertEqual(Darwin.read(fds[0], &buffer, 2), 2)
        XCTAssertEqual(buffer, Array("ok".utf8))
        XCTAssertEqual(Darwin.close(fds[0]), 0)
        XCTAssertEqual(Darwin.close(fds[1]), 0)
        XCTAssertEqual(Darwin.close(fds[1]), -1)
        XCTAssertEqual(Darwin.errno, EBADF)
    }

    func testLocalizedFallsBackToDefaultValue() {
        XCTAssertEqual(String(localized: "missing.key", defaultValue: "Fallback \(3)"), "Fallback 3")
    }
}
#endif

#if !canImport(os)
import CmuxLinuxCompat
import XCTest

final class LoggerShimTests: XCTestCase {
    func testPrivacyInterpolationRendersAndRedacts() {
        let secret = "token"
        let count = 3
        let message: OSLogMessage = "n=\(count, privacy: .public) s=\(secret, privacy: .private) h=\(secret, privacy: .private(mask: .hash)) f=\(1.5, format: .fixed(precision: 1))"
        Logger(subsystem: "test", category: "shim").error(message)
        XCTAssertEqual(Mirror(reflecting: message).children.first?.value as? String, "n=3 s=<private> h=<private> f=1.5")
    }

    func testUnfairLockMutatesState() {
        let lock = OSAllocatedUnfairLock(initialState: 0)
        lock.withLock { $0 += 2 }
        XCTAssertEqual(lock.withLock { $0 }, 2)
    }
}
#endif
