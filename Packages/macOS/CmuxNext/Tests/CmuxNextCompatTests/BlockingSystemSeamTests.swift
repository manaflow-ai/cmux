import ApplicationServices
@testable import CmuxNextCompat
import Darwin
import Foundation
import Security
import ServiceManagement
import Testing
import XPC

/// The checked seams over synchronous system calls (Security, Accessibility, host resolution, window
/// lists and captures, SMAppService, XPC replies; CmuxNextCompatAppKitTests checks the NSWorkspace queries): on
/// the main thread each one records exactly one site at its caller's line with its kind; on a named serial queue
/// none records. Each test binds its own table (``BlockingViolationTable/scoped``). The calls are chosen to change nothing on the host: the
/// keychain calls name an access group no test runner is entitled to, so securityd refuses the add
/// (`errSecMissingEntitlement`) and nothing is written; the AX calls go to this process's own element, with
/// its own short timeout, and name no real attribute or action; the captures name no window; the
/// SMAppService agent has no plist; the XPC send names a service that does not exist.
@Suite(.serialized)
struct BlockingSystemSeamTests {
    /// The names the debug log and the hang reports use never change.
    @Test func theSystemKindsKeepTheirNames() {
        #expect(BlockingKind.systemCall.rawValue == "system-call")
        #expect(BlockingKind.sleep.rawValue == "sleep")
        #expect(BlockingKind.ipcReply.rawValue == "ipc-reply")
        #expect(BlockingKind.xpcReply.rawValue == "xpc-reply")
    }

    #if DEBUG || CMUX_BLOCKING_CHECKS
    /// Each seam runs its call through `blockingCall`, so its site also carries the call's wall time (the
    /// injected clock measures every timed call as ``TickClock/tick``).
    @MainActor @Test func eachSeamOnTheMainThreadRecordsOneSiteAtItsCaller() async throws {
        let clock = TickClock()
        let table = BlockingViolationTable(mode: .record, uptimeNanos: { clock.read() })
        let expected = try BlockingViolationTable.$scoped.withValue(table) { try callEachSystemSeam() }
        await table.flush()

        #expect(expected.count == 22)
        #expect(Set(expected.map(\.location)).count == expected.count)
        #expect(BlockingDetector(table: table).sites == expected)
    }

    @MainActor @Test func theSameSeamsOnANamedSerialQueueRecordNothing() async throws {
        let table = BlockingViolationTable(mode: .record)
        let (onMain, called) = try await callEachSystemSeamOnNamedQueue(table)
        await table.flush()

        #expect(!onMain)
        #expect(called == 22)
        #expect(BlockingDetector(table: table).sites.isEmpty)
    }
    #endif
}

#if DEBUG || CMUX_BLOCKING_CHECKS
/// Calls every system seam once, on the caller's thread, and returns the site each call records on the
/// main thread (its kind and this file's line of the call).
private nonisolated func callEachSystemSeam() throws -> [BlockingSite] {
    var expected: [BlockingSite] = []
    func seam(_ kind: BlockingKind, fileID: StaticString = #fileID, line: UInt = #line, _ call: () -> Void) {
        expected.append(BlockingSite(kind: kind, location: "\(fileID):\(line)", count: 1,
                                     totalNanos: TickClock.tick, maxNanos: TickClock.tick))
        call()
    }

    let attributes: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecUseDataProtectionKeychain: true,
                                       kSecAttrAccessGroup: "com.cmuxterm.tests.no-such-access-group",
                                       kSecAttrService: "com.cmuxterm.tests.blocking-seam.\(UUID().uuidString)"]
    let item = attributes as CFDictionary
    seam(.systemCall) { _ = blockingSecItemCopyMatching(item, nil) }
    seam(.systemCall) { _ = blockingSecItemAdd(item, nil) }
    let update: [CFString: Any] = [kSecAttrLabel: "updated"]
    seam(.systemCall) { _ = blockingSecItemUpdate(item, update as CFDictionary) }
    seam(.systemCall) { _ = blockingSecItemDelete(item) }

    var anchors: CFArray?
    _ = SecTrustCopyAnchorCertificates(&anchors)
    let anchor = try #require((anchors as? [SecCertificate])?.first)
    var madeTrust: SecTrust?
    _ = SecTrustCreateWithCertificates(anchor, SecPolicyCreateBasicX509(), &madeTrust)
    let trust = try #require(madeTrust)
    _ = SecTrustSetNetworkFetchAllowed(trust, false)
    seam(.systemCall) { _ = blockingSecTrustEvaluate(trust, nil) }

    var madeCode: SecStaticCode?
    _ = SecStaticCodeCreateWithPath(URL(fileURLWithPath: "/usr/bin/true") as CFURL, [], &madeCode)
    let code = try #require(madeCode)
    seam(.systemCall) { _ = blockingSecStaticCodeCheckValidity(code, [], nil) }
    var information: CFDictionary?
    seam(.systemCall) { _ = blockingSecCodeCopySigningInformation(code, [], &information) }

    var madeSelf: SecCode?
    seam(.systemCall) { _ = blockingSecCodeCopySelf([], &madeSelf) }
    let selfCode = try #require(madeSelf)
    var selfOnDisk: SecStaticCode?
    seam(.systemCall) { _ = blockingSecCodeCopyStaticCode(selfCode, [], &selfOnDisk) }
    var guest: SecCode?
    let guestAttributes = [kSecGuestAttributePid: getpid()] as CFDictionary
    seam(.systemCall) { _ = blockingSecCodeCopyGuestWithAttributes(nil, guestAttributes, [], &guest) }

    var madeAuthorization: AuthorizationRef?
    _ = AuthorizationCreate(nil, nil, [], &madeAuthorization)
    let authorization = try #require(madeAuthorization)
    defer { AuthorizationFree(authorization, []) }
    var noRights = AuthorizationRights(count: 0, items: nil)
    seam(.systemCall) { _ = blockingAuthorizationCopyRights(authorization, &noRights, nil, [], nil) }

    // This element's own timeout: the system-wide element's would change every later AX call in the process.
    let ownApp = AXUIElementCreateApplication(getpid())
    _ = AXUIElementSetMessagingTimeout(ownApp, 0.25)
    let unknown = "AXCmuxBlockingSeamTest" as CFString
    var value: CFTypeRef?
    seam(.systemCall) { _ = blockingAXCopyAttributeValue(ownApp, unknown, &value) }
    seam(.systemCall) { _ = blockingAXSetAttributeValue(ownApp, unknown, kCFBooleanFalse) }
    seam(.systemCall) { _ = blockingAXPerformAction(ownApp, unknown) }

    var hints = addrinfo()
    hints.ai_flags = AI_NUMERICHOST
    var info: UnsafeMutablePointer<addrinfo>?
    seam(.systemCall) { _ = blockingGetaddrinfo("127.0.0.1", nil, &hints, &info) }
    freeaddrinfo(info)

    seam(.systemCall) { _ = blockingWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) }
    seam(.systemCall) { _ = blockingWindowListCreateImage(.null, .optionIncludingWindow, kCGNullWindowID, []) }
    seam(.systemCall) { _ = blockingWindowListCreateImageFromArray(.null, [], []) }

    let missingAgent = SMAppService.agent(plistName: "com.cmuxterm.tests.blocking-seam.plist")
    seam(.ipcReply) { _ = blockingSMAppServiceStatus(missingAgent) }
    seam(.ipcReply) { _ = try? blockingSMAppServiceRegister(missingAgent) }
    seam(.ipcReply) { _ = try? blockingSMAppServiceUnregister(missingAgent) }

    // No such service is registered, so the reply is an XPC_TYPE_ERROR at once.
    let connection = xpc_connection_create_mach_service("com.cmuxterm.blocking-probe.none", nil, 0)
    xpc_connection_set_event_handler(connection) { _ in }
    xpc_connection_resume(connection)
    defer { xpc_connection_cancel(connection) }
    let request = xpc_dictionary_create(nil, nil, 0)
    seam(.xpcReply) { _ = blockingXPCSendWithReply(connection, request) }
    return expected
}

/// A clock that moves ``tick`` nanoseconds per read, so each timed call (two reads) measures ``tick``.
private nonisolated final class TickClock: Sendable {
    static let tick: UInt64 = 1_000
    private let now = Mutex(UInt64(0))

    func read() -> UInt64 {
        now.withLock { now in
            now += Self.tick
            return now
        }
    }
}

/// The same calls on a named serial queue, a context where blocking is allowed (not the cooperative pool
/// or a GCD root queue), with `table` bound there. Returns whether they ran on the main thread and how many
/// seams they called.
private nonisolated func callEachSystemSeamOnNamedQueue(_ table: BlockingViolationTable) async throws -> (Bool, Int) {
    let queue = DispatchQueue(label: "com.cmuxterm.tests.blocking-system-seams")
    return try await withCheckedThrowingContinuation { continuation in
        queue.async {
            continuation.resume(with: Result {
                try BlockingViolationTable.$scoped.withValue(table) { (pthread_main_np() != 0, try callEachSystemSeam().count) }
            })
        }
    }
}
#endif
