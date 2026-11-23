import CmuxNextSettings
import Foundation
import Testing

/// 2026-11-16, Settings opens late: each open's host lists looked up every size row's descriptor by
/// path (SettingsUnsetSizes.derivedNumbers), and each lookup scanned the whole schema, 9-11 ms a
/// main-thread record on cmux-lawrence-2 (debug.hangs on 9c89f8f). A lookup takes the same time
/// for the schema's last setting as for its first.
@MainActor struct SettingsDescriptorLookupTests {
    private static func fastest(_ path: [String]) -> Duration {
        let clock = ContinuousClock()
        return (0..<5).map { _ in clock.measure { for _ in 0..<300 { _ = SettingsSchema.descriptor(for: path) } } }.min() ?? .zero
    }

    @Test func aLookupDoesNotScanTheWholeSchema() throws {
        let first = try #require(SettingsSchema.all.first?.path), last = try #require(SettingsSchema.all.last?.path)
        #expect(SettingsSchema.descriptor(for: last)?.path == last)
        #expect(SettingsSchema.descriptor(for: ["no", "such", "setting"]) == nil)
        let near = Self.fastest(first), far = Self.fastest(last)
        #expect(far < near * 10, "the last setting's lookup took \(far), the first's \(near): a scan of \(SettingsSchema.all.count) settings")
    }
}
