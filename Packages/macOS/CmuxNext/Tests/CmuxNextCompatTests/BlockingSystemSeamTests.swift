import AppKit
import ApplicationServices
@testable import CmuxNextCompat
import Darwin
import Foundation
import Security
import ServiceManagement
import Testing

/// The checked seams over synchronous system calls (Security, Accessibility, host resolution, window
/// lists, NSWorkspace queries, SMAppService): on the main thread each one records exactly one site at its
/// caller's line with its kind; off the main thread none records. Each test binds its own table
/// (``BlockingViolationTable/scoped``). The calls are chosen to change nothing on the host: keychain calls
/// name a data-protection item that does not exist, AX calls name no real attribute or action, the
/// SMAppService agent has no plist.
@Suite(.serialized)
struct BlockingSystemSeamTests {
    /// The names the debug log and the hang reports use never change.
    @Test func theSystemKindsKeepTheirNames() {
        #expect(BlockingKind.systemCall.rawValue == "system-call")
        #expect(BlockingKind.sleep.rawValue == "sleep")
        #expect(BlockingKind.ipcReply.rawValue == "ipc-reply")
    }

    #if DEBUG || CMUX_BLOCKING_CHECKS
    @MainActor @Test func eachSeamOnTheMainThreadRecordsOneSiteAtItsCaller() async throws {
        let table = BlockingViolationTable(mode: .record)
        let expected = try BlockingViolationTable.$scoped.withValue(table) { try callEachSystemSeam() }
        await table.flush()

        #expect(expected.count == 19)
        #expect(Set(expected.map(\.location)).count == expected.count)
        #expect(BlockingDetector(table: table).sites == expected)
    }

    @MainActor @Test func theSameSeamsOffTheMainThreadRecordNothing() async throws {
        let table = BlockingViolationTable(mode: .record)
        let called = try await BlockingViolationTable.$scoped.withValue(table) { try await callEachSystemSeamOffMain() }
        await table.flush()

        #expect(called == 19)
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
        expected.append(BlockingSite(kind: kind, location: "\(fileID):\(line)", count: 1))
        call()
    }

    let attributes: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecUseDataProtectionKeychain: true,
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

    var madeAuthorization: AuthorizationRef?
    _ = AuthorizationCreate(nil, nil, [], &madeAuthorization)
    let authorization = try #require(madeAuthorization)
    defer { AuthorizationFree(authorization, []) }
    var noRights = AuthorizationRights(count: 0, items: nil)
    seam(.ipcReply) { _ = blockingAuthorizationCopyRights(authorization, &noRights, nil, [], nil) }

    let systemWide = AXUIElementCreateSystemWide()
    _ = AXUIElementSetMessagingTimeout(systemWide, 0.25)
    let unknown = "AXCmuxBlockingSeamTest" as CFString
    var value: CFTypeRef?
    seam(.systemCall) { _ = blockingAXCopyAttributeValue(systemWide, unknown, &value) }
    seam(.systemCall) { _ = blockingAXSetAttributeValue(systemWide, unknown, kCFBooleanFalse) }
    seam(.systemCall) { _ = blockingAXPerformAction(systemWide, unknown) }

    var hints = addrinfo()
    hints.ai_flags = AI_NUMERICHOST
    var info: UnsafeMutablePointer<addrinfo>?
    seam(.systemCall) { _ = blockingGetaddrinfo("127.0.0.1", nil, &hints, &info) }
    freeaddrinfo(info)

    seam(.systemCall) { _ = blockingWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) }

    let workspace = NSWorkspace.shared
    let hosts = URL(fileURLWithPath: "/etc/hosts")
    seam(.systemCall) { _ = workspace.blockingURLForApplication(withBundleIdentifier: "com.apple.finder") }
    seam(.systemCall) { _ = workspace.blockingURLForApplication(toOpen: hosts) }
    seam(.systemCall) { _ = workspace.blockingURLsForApplications(toOpen: hosts) }
    seam(.systemCall) { _ = workspace.blockingIcon(forFile: hosts.path) }

    let missingAgent = SMAppService.agent(plistName: "com.cmuxterm.tests.blocking-seam.plist")
    seam(.ipcReply) { _ = missingAgent.blockingStatus() }
    seam(.ipcReply) { _ = try? missingAgent.blockingRegister() }
    seam(.ipcReply) { _ = try? missingAgent.blockingUnregister() }
    return expected
}

/// The same calls on a thread of the global executor, in the caller's task (its task-local table applies).
@concurrent
private nonisolated func callEachSystemSeamOffMain() async throws -> Int {
    #expect(pthread_main_np() == 0)
    return try callEachSystemSeam().count
}
#endif
