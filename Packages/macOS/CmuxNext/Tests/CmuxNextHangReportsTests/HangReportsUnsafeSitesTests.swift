import CmuxNextCompat
import Darwin
import Foundation
@testable import CmuxNextHangReports
import Testing

/// The HangReports sites now written `unsafe` with a SAFETY argument behave as before. The
/// dyld resolver finds a loaded image by address and by UUID, and the blocking site id is the same FNV-1a hash
/// of the kind, the context and each frame's UUID bytes and little-endian offset.
struct HangReportsUnsafeSitesTests {
    /// The address of `malloc`, in libsystem_malloc (the dyld shared cache on every supported macOS).
    private static func mallocAddress() -> UInt64? {
        // SAFETY: dlsym reads the NUL-terminated copy of the name made for the call; RTLD_DEFAULT (-2) is a handle
        // value dlsym defines. The result is used as an integer address only.
        guard let symbol = unsafe dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc") else { return nil }
        return unsafe UInt64(UInt(bitPattern: symbol))
    }

    @Test func theDyldResolverFindsAnImageByAddressAndAgainByItsUUID() {
        guard let address = Self.mallocAddress() else {
            Issue.record("dlsym found no malloc")
            return
        }
        let resolver = DyldImageResolver()
        let byAddress = resolver.image(containing: address)
        #expect(byAddress?.contains(address) == true)
        #expect(byAddress?.path.hasSuffix(".dylib") == true)
        guard let byAddress else { return }
        #expect(resolver.image(uuid: byAddress.uuid) == byAddress)
        #expect(resolver.image(uuid: byAddress.uuid.lowercased()) == byAddress)
    }

    @Test func theDyldResolverFindsNothingForAnUnmappedAddressOrAnUnknownUUID() {
        let resolver = DyldImageResolver()
        #expect(resolver.image(containing: 0) == nil)
        #expect(resolver.image(uuid: "00000000-0000-0000-0000-000000000000") == nil)
    }

    @Test func theSiteIdIsTheFNV1aHashOfTheKindContextAndFrameBytes() throws {
        let first = try #require(UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF"))
        let second = try #require(UUID(uuidString: "F0E1D2C3-B4A5-9687-7869-5A4B3C2D1E0F"))
        let violation = BlockingViolation(kind: .fileIO, context: .main, frames: [
            BlockingFrame(imageUUID: first, offset: 0x1234_5678_9ABC),
            BlockingFrame(imageUUID: second, offset: 0x40),
        ])
        // FNV-1a 64 over "file-io", 0, "main", then per frame its 16 UUID bytes and 8 little-endian offset bytes.
        #expect(BlockingReportBudget.site(of: violation) == "b2060c4f36c9f201")
    }

    /// sysctlbyname reads `hw.machine`: every supported Mac is arm64 or x86_64, so `other` means the read failed.
    @Test func theHardwareClassReadsTheArchitectureBySysctl() {
        #expect(["arm64", "x86_64"].contains(HardwareClass.current().arch))
    }

    /// gethostname always names the host, so the terms hold at least one host label after the user's names.
    @Test func thePersonalTermsHoldTheHostNameLabels() {
        let full = NSFullUserName().split { !$0.isLetter && !$0.isNumber }
        let terms = ImageClassifier.personalTerms()
        #expect(terms.count > 2 + full.count)
        #expect(terms.dropFirst(2 + full.count).allSatisfy { !$0.isEmpty && !$0.contains(".") && $0 != "local" })
    }
}
