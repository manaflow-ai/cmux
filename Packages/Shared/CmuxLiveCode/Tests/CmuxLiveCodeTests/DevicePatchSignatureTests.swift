import Foundation
import Testing
@testable import CmuxLiveCode

/// A cmux Dev app on a device loads only a patch its own team signed, not ad hoc
/// (DevicePatchSignature.swift), and only cmux Dev or a tagged dev build launched for it runs live
/// code (LiveCodeDeviceGate). The Mach-O files here are built byte by byte: a header, one
/// LC_CODE_SIGNATURE, and a SuperBlob with a CodeDirectory and, when signed, a CMS blob.
struct DevicePatchSignatureTests {
    private static func be(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }

    private static func le(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 24)]
    }

    /// A thin arm64 Mach-O signed by `team` (nil: none), ad hoc or not, with a CMS blob or not.
    static func machO(team: String?, adhoc: Bool = false, cms: Bool = true, version: UInt32 = 0x20400) -> [UInt8] {
        var directory = be(0xFADE_0C02) + be(0) + be(version) + be(adhoc ? 0x2 : 0)
        directory += [UInt8](repeating: 0, count: 48 - directory.count)
        let teamBytes: [UInt8] = team.map { Array($0.utf8) + [0] } ?? []
        directory += be(team == nil ? 0 : 56) + be(0)
        directory += teamBytes
        let length = UInt32(directory.count)
        directory.replaceSubrange(4..<8, with: be(length))
        let signature = be(0xFADE_0B01) + be(cms ? 24 : 8) + (cms ? [UInt8](repeating: 0xAB, count: 16) : [])
        let count: UInt32 = 2
        let headerSize = 12 + Int(count) * 8
        var blob = be(0xFADE_0CC0) + be(0) + be(count)
        blob += be(0) + be(UInt32(headerSize))
        blob += be(0x10000) + be(UInt32(headerSize + directory.count))
        blob += directory + signature
        blob.replaceSubrange(4..<8, with: be(UInt32(blob.count)))
        let dataoff: UInt32 = 32 + 16
        var file = le(0xFEED_FACF) + le(0x0100_000C) + le(0) + le(6) + le(1) + le(16) + le(0) + le(0)
        file += le(0x1D) + le(16) + le(dataoff) + le(UInt32(blob.count))
        return file + blob
    }

    /// `thin` inside a fat file, beside an x86_64 slice of junk.
    static func fat(_ thin: [UInt8]) -> [UInt8] {
        let x86 = [UInt8](repeating: 0, count: 64)
        let header = be(0xCAFE_BABE) + be(2)
        let first = 8 + 2 * 20
        var file = header
        file += be(0x0100_0007) + be(3) + be(UInt32(first)) + be(UInt32(x86.count)) + be(0)
        file += be(0x0100_000C) + be(0) + be(UInt32(first + x86.count)) + be(UInt32(thin.count)) + be(0)
        return file + x86 + thin
    }

    @Test func readsTheTeamTheFlagsAndTheSignature() throws {
        let signature = try MachOCodeSignature.read(Data(Self.machO(team: "7WLXT3NR37")))
        #expect(signature == MachOCodeSignature(teamID: "7WLXT3NR37", adhoc: false, signed: true))
        let adhoc = try MachOCodeSignature.read(Data(Self.machO(team: nil, adhoc: true, cms: false)))
        #expect(adhoc == MachOCodeSignature(teamID: nil, adhoc: true, signed: false))
        // A CodeDirectory older than the team field names none.
        let old = try MachOCodeSignature.read(Data(Self.machO(team: "7WLXT3NR37", version: 0x20100)))
        #expect(old.teamID == nil)
    }

    @Test func readsTheArm64SliceOfAFatFile() throws {
        let signature = try MachOCodeSignature.read(Data(Self.fat(Self.machO(team: "ABCDE12345"))))
        #expect(signature.teamID == "ABCDE12345")
    }

    @Test func anUnsignedOrBrokenFileIsRefused() {
        #expect(throws: LiveCodeError.self) { try MachOCodeSignature.read(Data([1, 2, 3])) }
        var unsigned = Self.machO(team: "7WLXT3NR37")
        unsigned.replaceSubrange(32..<36, with: Self.le(0x19)) // LC_SEGMENT_64, not a signature
        #expect(throws: LiveCodeError.self) { try MachOCodeSignature.read(Data(unsigned)) }
        // A signature that points past the file.
        let truncated = Array(Self.machO(team: "7WLXT3NR37").prefix(60))
        #expect(throws: LiveCodeError.self) { try MachOCodeSignature.read(Data(truncated)) }
    }

    @Test func onlyThisTeamsRealSignatureLoads() throws {
        try DevicePatchSignature.check(Data(Self.machO(team: "7WLXT3NR37")), team: "7WLXT3NR37")
        #expect(throws: LiveCodeError.self) {
            try DevicePatchSignature.check(Data(Self.machO(team: "ZZZZZZZZZZ")), team: "7WLXT3NR37")
        }
        #expect(throws: LiveCodeError.self) {
            try DevicePatchSignature.check(Data(Self.machO(team: nil, adhoc: true, cms: false)), team: "7WLXT3NR37")
        }
        // Ad hoc even with a team string and a blob: refused.
        #expect(throws: LiveCodeError.self) {
            try DevicePatchSignature.check(Data(Self.machO(team: "7WLXT3NR37", adhoc: true)), team: "7WLXT3NR37")
        }
        // A team, not ad hoc, but no certificate's signature.
        #expect(throws: LiveCodeError.self) {
            try DevicePatchSignature.check(Data(Self.machO(team: "7WLXT3NR37", cms: false)), team: "7WLXT3NR37")
        }
    }

    @Test func theAppsOwnSignatureNamesTheTeam() {
        #expect(LiveCodeDeviceSigner.of(app: Data(Self.machO(team: "7WLXT3NR37"))) == .team("7WLXT3NR37"))
        if case .refuseAll = LiveCodeDeviceSigner.of(app: Data(Self.machO(team: nil, adhoc: true, cms: false))) {} else {
            Issue.record("an ad hoc app must refuse every patch")
        }
        if case .refuseAll = LiveCodeDeviceSigner.of(app: Data([0, 1])) {} else {
            Issue.record("an unreadable app must refuse every patch")
        }
        #expect(!LiveCodeDeviceSigner.isTeamID("7wlxt3nr37"))
        #expect(!LiveCodeDeviceSigner.isTeamID("7WLXT3NR3"))
    }

    @Test func refuseAllRefusesAndAnyTakesEverything() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("live-\(UUID().uuidString).dylib")
        try Data(Self.machO(team: nil, adhoc: true, cms: false)).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        try DevicePatchSignature.check(file.path, signer: .any)
        #expect(throws: LiveCodeError.self) { try DevicePatchSignature.check(file.path, signer: .refuseAll("no team")) }
        #expect(throws: LiveCodeError.self) { try DevicePatchSignature.check(file.path, signer: .team("7WLXT3NR37")) }
    }

    @Test func onlyADevBuildLaunchedForItRunsLiveCode() {
        let on = ["CMUX_LIVE_CODE_LINK": "1"]
        #expect(LiveCodeDeviceGate.allows(bundleID: "dev.cmux.mobile.dev", environment: on))
        #expect(LiveCodeDeviceGate.allows(bundleID: "dev.cmux.mobile.my-task", environment: on))
        #expect(!LiveCodeDeviceGate.allows(bundleID: "dev.cmux.mobile.dev", environment: [:]))
        #expect(!LiveCodeDeviceGate.allows(bundleID: "dev.cmux.mobile.dev", environment: ["CMUX_LIVE_CODE_LINK": "0"]))
        // INTERNAL, the App Store app, and the untagged prefix itself.
        #expect(!LiveCodeDeviceGate.allows(bundleID: "dev.cmux.app.internal", environment: on))
        #expect(!LiveCodeDeviceGate.allows(bundleID: "com.cmux.app", environment: on))
        #expect(!LiveCodeDeviceGate.allows(bundleID: "dev.cmux.mobile.", environment: on))
        #expect(!LiveCodeDeviceGate.allows(bundleID: nil, environment: on))
    }
}
