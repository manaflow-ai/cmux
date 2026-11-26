import Foundation
import Testing
@testable import CmuxMobileNotifications

/// The app reads its own signed App Groups before it asks containermanagerd
/// for one, and shares Require Face ID through the push keychain group, which
/// every build is signed with (the CI App Store profiles grant no App Group).
@Suite struct SignedEntitlementsTests {
    static func plist(groups: [String]?) throws -> Data {
        var entitlements: [String: Any] = ["keychain-access-groups": ["7WLXT3NR37.dev.cmux.app.internal.push"]]
        if let groups { entitlements[SignedEntitlements.applicationGroupsKey] = groups }
        return try PropertyListSerialization.data(fromPropertyList: entitlements, format: .xml, options: 0)
    }

    static func le32(_ v: UInt32) -> [UInt8] { withUnsafeBytes(of: v.littleEndian, Array.init) }
    static func be32(_ v: UInt32) -> [UInt8] { withUnsafeBytes(of: v.bigEndian, Array.init) }
    static func le64(_ v: UInt64) -> [UInt8] { withUnsafeBytes(of: v.littleEndian, Array.init) }
    static func name(_ s: String) -> [UInt8] { Array(s.utf8) + Array(repeating: 0, count: 16 - s.utf8.count) }

    static func header(commands: UInt32, size: UInt32) -> [UInt8] {
        le32(0xfeed_facf) + le32(0x0100_000c) + le32(0) + le32(2) + le32(commands) + le32(size) + le32(0) + le32(0)
    }

    /// A device build: the entitlements blob of the code signature.
    static func signed(_ xml: Data) -> Data {
        let blob = be32(0xfade_7171) + be32(UInt32(8 + xml.count)) + Array(xml)
        let superBlob = be32(0xfade_0cc0) + be32(UInt32(20 + blob.count)) + be32(1) + be32(5) + be32(20) + blob
        let command = le32(0x1d) + le32(16) + le32(48) + le32(UInt32(superBlob.count))
        return Data(header(commands: 1, size: 16) + command + superBlob)
    }

    /// A simulator build: the `__TEXT,__entitlements` section.
    static func simulator(_ xml: Data) -> Data {
        let offset = 32 + 152
        let section = name("__entitlements") + name("__TEXT") + le64(0) + le64(UInt64(xml.count)) + le32(UInt32(offset))
            + Array(repeating: 0, count: 80 - 52)
        let segment = le32(0x19) + le32(152) + name("__TEXT") + Array(repeating: 0, count: 64 - 24) + le32(1) + le32(0) + section
        return Data(header(commands: 1, size: 152) + segment + Array(xml))
    }

    static func file(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("entitlements-\(UUID().uuidString)")
        try data.write(to: url)
        return url
    }

    @Test func theCIProfilesSignatureHasNoGroup() throws {
        let url = try Self.file(Self.signed(Self.plist(groups: nil)))
        #expect(SignedEntitlements.applicationGroups(executable: url) == [])
    }

    @Test func aSignatureWithTheGroupNamesIt() throws {
        let url = try Self.file(Self.signed(Self.plist(groups: ["group.dev.cmux.app.internal"])))
        #expect(SignedEntitlements.applicationGroups(executable: url) == ["group.dev.cmux.app.internal"])
    }

    @Test func aSimulatorBuildsSectionIsRead() throws {
        let url = try Self.file(Self.simulator(Self.plist(groups: ["group.dev.cmux.mobile"])))
        #expect(SignedEntitlements.applicationGroups(executable: url) == ["group.dev.cmux.mobile"])
    }

    @Test func unreadableEntitlementsAreUnknown() throws {
        let url = try Self.file(Data("not a Mach-O".utf8))
        #expect(SignedEntitlements.applicationGroups(executable: url) == nil)
        #expect(SignedEntitlements.applicationGroups(executable: nil) == nil)
        let truncated = Self.signed(try Self.plist(groups: nil)).prefix(60)
        #expect(SignedEntitlements.applicationGroups(executable: try Self.file(truncated)) == nil)
    }

    @Test func requireFaceIDIsSharedWithoutTheAppGroup() {
        let keychain = PushMemoryStore()
        let app = PushSharedPreference(keychain: keychain, defaults: nil)
        let extensionSide = PushSharedPreference(keychain: keychain, defaults: nil)
        #expect(!extensionSide.requireFaceID)
        app.setRequireFaceID(true)
        #expect(extensionSide.requireFaceID)
        #expect(PushActions(preference: extensionSide).opensApp(.deny))
        app.setRequireFaceID(false)
        #expect(!extensionSide.requireFaceID)
    }

    @Test func anOlderAppsGroupDefaultsStillCount() throws {
        let defaults = try #require(UserDefaults(suiteName: "push-shared-\(UUID().uuidString)"))
        defaults.set(true, forKey: PushActions.requireFaceIDKey)
        #expect(PushSharedPreference(keychain: PushMemoryStore(), defaults: defaults).requireFaceID)
        let keychain = PushMemoryStore()
        PushSharedPreference(keychain: keychain, defaults: defaults).setRequireFaceID(false)
        #expect(!PushSharedPreference(keychain: keychain, defaults: nil).requireFaceID)
        #expect(!defaults.bool(forKey: PushActions.requireFaceIDKey))
    }

    /// RootView's body sets the choice on every pass: only a change writes, so the
    /// first frame cannot loop on its own defaults write.
    @Test func anUnchangedFaceIDChoiceWritesNothing() {
        var sync = PushFaceIDSync(local: false)
        #expect(sync.set(false) == .init(local: false, shared: true))
        for _ in 0..<50 { #expect(sync.set(false) == .init(local: false, shared: false)) }
        #expect(sync.set(true) == .init(local: true, shared: true))
        #expect(sync.set(true) == .init(local: false, shared: false))
        #expect(sync.local)
    }
}
