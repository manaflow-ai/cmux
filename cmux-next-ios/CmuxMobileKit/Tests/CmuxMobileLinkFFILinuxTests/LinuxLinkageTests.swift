// RFD 0051 route 2: Swift calling the Rust FFI through the checked-in uniffi binding on Linux.
// The reliability projection drives scripted transports, so it proves controller logic only; these
// tests link libcmux_mobile_link_ffi.a and cross the boundary for real: strings, records, enums,
// objects, errors lifted from Rust, a Swift callback Rust calls (and its error), and an async call.
// Run with rust/scripts/build-linux-ffi.sh (the manifest only defines this target under its env).
import Crypto
import Foundation
import Testing
import CmuxMobileLinkFFI

private struct Vectors {
    let mac: String
    let phone: String
    let macIdentityKey: String
    let macBoxKey: String
    let macBoxSignature: String
    let phoneIdentityScalar: String
    let phoneIdentityKey: String

    static func load(filePath: String = #filePath) throws -> Vectors {
        // Tests/CmuxMobileLinkFFILinuxTests/<file> -> cmux-next-ios
        let root = URL(fileURLWithPath: filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("rust/crates/cmux-mobile-host/tests/fixtures/seal-vectors.json")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
        func field(_ key: String) throws -> String {
            guard let value = json[key] as? String else { throw FixtureMissing(key: key) }
            return value
        }
        return Vectors(
            mac: try field("mac"), phone: try field("phone"), macIdentityKey: try field("macIdentityKey"),
            macBoxKey: try field("macBoxKey"), macBoxSignature: try field("macBoxSignature"),
            phoneIdentityScalar: try field("phoneIdentityScalar"), phoneIdentityKey: try field("phoneIdentityKey"))
    }
}

private struct FixtureMissing: Error { let key: String }

private func hexBytes(_ hex: String) -> Data {
    var out = Data(capacity: hex.count / 2)
    var index = hex.startIndex
    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2)
        out.append(UInt8(hex[index..<next], radix: 16)!)
        index = next
    }
    return out
}

/// The phone identity key as the app's signer would be, but in software: Rust calls back into it.
private final class SoftwareSigner: MailboxSigner, @unchecked Sendable {
    private let key: P256.Signing.PrivateKey
    private let lock = NSLock()
    private var count = 0
    var calls: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    init(scalarHex: String) throws {
        key = try P256.Signing.PrivateKey(rawRepresentation: hexBytes(scalarHex))
    }

    func sign(message: Data) throws -> Data {
        lock.lock()
        count += 1
        lock.unlock()
        return try key.signature(for: message).rawRepresentation
    }
}

private final class RefusingSigner: MailboxSigner, @unchecked Sendable {
    func sign(message: Data) throws -> Data {
        throw MailboxSignError.Failed(message: "refused on purpose")
    }
}

private let now: UInt64 = 1_792_540_900

private func spec(_ v: Vectors) -> MailboxItemSpec {
    MailboxItemSpec(
        id: "7c1e9a52-3b44-4d0e-9d6a-1f2e3d4c5b6a", mac: v.mac, phone: v.phone, kind: "completed",
        target: MailboxTarget(sessionId: "s1", permissionId: nil, conversationId: nil, tabId: nil, notificationId: nil),
        action: .text(text: "ship it", steer: nil), approvalJson: nil, nonce: nil, issuedAt: now - 10,
        lifetimeSecs: nil)
}

@Suite struct LinuxLinkageTests {
    @Test func aStringComesBackFromRust() {
        // The checksum check in the binding's init already ran: a mismatched library fails here.
        #expect(cmuxMobileVersion() == "0.1.0")
    }

    @Test func aRecordComesBackFromRust() {
        let phone = windowLayout(width: 390, height: 844)
        let tablet = windowLayout(width: 1024, height: 1366)
        #expect(!phone.twoPane)
        #expect(tablet.unfolded)
        #expect(tablet.twoPane)
        #expect(tablet.listWidth + tablet.detailWidth <= 1024)
    }

    @Test func anEnumInARecordRoundTrips() {
        let filter = PaneFilter(scope: .agentsAndTerminals, showBrowsers: true)
        #expect(paneFilterDecode(saved: paneFilterEncode(filter: filter)) == filter)
        #expect(paneFilterDecode(saved: "not a saved filter") == paneFilterDefault())
    }

    @Test func aU64ComesBackStable() {
        #expect(rowLayoutFingerprint(text: "hello") == rowLayoutFingerprint(text: "hello"))
        #expect(rowLayoutFingerprint(text: "hello") != rowLayoutFingerprint(text: "hello!"))
    }

    @Test func rustErrorsLiftToSwiftErrors() throws {
        let v = try Vectors.load()
        #expect(throws: MailboxError.UntrustedBoxKey) {
            // A box key with no signature and no pinned identity proves nothing.
            try mailboxTrustedBoxKey(mac: v.mac, boxKey: v.macBoxKey, boxSignature: nil, pinnedIdentity: nil)
        }
    }

    @Test func rustCallsASwiftSigner() throws {
        let v = try Vectors.load()
        let boxKey = try mailboxTrustedBoxKey(
            mac: v.mac, boxKey: v.macBoxKey, boxSignature: v.macBoxSignature, pinnedIdentity: v.macIdentityKey)
        let signer = try SoftwareSigner(scalarHex: v.phoneIdentityScalar)
        let sealed = try mailboxBuild(spec: spec(v), boxKey: boxKey, signer: signer, now: now)
        #expect(signer.calls >= 1)
        #expect(sealed.mac == v.mac)
        #expect(sealed.phone == v.phone)
        #expect(sealed.expiresAt == now - 10 + 540)
        #expect(!sealed.sealed.isEmpty)
    }

    @Test func aSwiftSignerErrorReachesRustAndComesBack() throws {
        let v = try Vectors.load()
        let boxKey = try mailboxTrustedBoxKey(
            mac: v.mac, boxKey: v.macBoxKey, boxSignature: v.macBoxSignature, pinnedIdentity: v.macIdentityKey)
        #expect(throws: (any Error).self) {
            try mailboxBuild(spec: spec(v), boxKey: boxKey, signer: RefusingSigner(), now: now)
        }
    }

    @Test func anAsyncCallCompletesThroughRustFutures() async {
        // No reachable endpoint: connect_local must fail, and the failure must come back through the
        // foreign-future poll and the error lift instead of hanging.
        let outcome = await withTaskGroup(of: String.self) { group in
            group.addTask {
                do {
                    _ = try await connectLocal(
                        deviceId: "a2b4c6d8-1e3f-4a5b-8c7d-9e0f1a2b3c4d",
                        macDeviceId: "6f1c2a7e-0b1d-4c55-9a43-2d8e5b7f3c10",
                        endpoints: [LocalEndpoint(host: "127.0.0.1", port: 9)], transport: .webRtc, observer: nil)
                    return "connected"
                } catch {
                    return "threw"
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                return "timed out"
            }
            let first = await group.next() ?? "none"
            group.cancelAll()
            return first
        }
        #expect(outcome == "threw")
        await resetWarmState()
    }
}
