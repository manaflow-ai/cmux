import CmuxNextSettings
import Testing

/// `remoteDesktop.*` (Settings > cmux Remote > Screen Sharing Quality, Frame Rate Limit, Bitrate Limit):
/// unset reads Auto everywhere, so a new session's offer is today's; numbers are kept and clamped to their rows.
struct RemoteDesktopDefaultsSettingsTests {
    private static func parse(_ members: [String: JSONValue]?) -> CmuxConfigSnapshot {
        let root: JSONValue = members.map { .object(["remoteDesktop": .object($0)]) } ?? .object([:])
        return CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
    }

    @Test func unsetIsAutoAndTheRowsSaySo() throws {
        let snapshot = Self.parse(nil)
        #expect(snapshot.remoteDesktop == RemoteDesktopDefaults())
        #expect(snapshot.remoteDesktop.quality == .auto && snapshot.remoteDesktop.maxFps == nil && snapshot.remoteDesktop.maxKbps == nil)
        #expect(snapshot.diagnostics.isEmpty)
        let quality = try #require(SettingsSchema.descriptor(for: RemoteDesktopDefaults.qualityPath), "Settings has no Screen Sharing Quality row")
        #expect(quality.defaultValue == .string("auto"))
        #expect(SettingsSchema.descriptor(for: RemoteDesktopDefaults.maxFpsPath) != nil)
        #expect(SettingsSchema.descriptor(for: RemoteDesktopDefaults.maxBitrateMbpsPath) != nil)
    }

    @Test func picksAreKeptAndNumbersClamped() {
        let picked = Self.parse(["quality": .string("lowBandwidth"), "maxFps": .number(30), "maxBitrateMbps": .number(2.5)]).remoteDesktop
        #expect(picked.quality == .lowBandwidth && picked.maxFps == 30 && picked.maxKbps == 2500)
        let auto = Self.parse(["maxFps": .string("auto"), "maxBitrateMbps": .string("auto")])
        #expect(auto.remoteDesktop.maxFps == nil && auto.remoteDesktop.maxKbps == nil && auto.diagnostics.isEmpty)
        let wild = Self.parse(["maxFps": .number(1000), "maxBitrateMbps": .number(0.1)])
        #expect(wild.remoteDesktop.maxFps == 240 && wild.remoteDesktop.maxKbps == 500)
        #expect(!wild.diagnostics.isEmpty, "a clamped number says nothing")
    }

    /// Settings > Customize "Sharper Text from Linux Machines": off unless the person turns it on, a
    /// toggle row in Settings (CloudDesktopLinkTests: the Open Desktop hello offers `video.sharp_text` only then).
    @Test func sharpLinuxTextIsOffUntilTurnedOnAndOffersTheCap() throws {
        #expect(!Self.parse(nil).remoteDesktop.sharpLinuxText)
        let row = try #require(SettingsSchema.descriptor(for: RemoteDesktopDefaults.sharpLinuxTextPath), "Settings has no Sharper Text from Linux Machines row")
        #expect(row.defaultValue == .bool(false))
        let on = Self.parse(["sharpLinuxText": .bool(true)])
        #expect(on.remoteDesktop.sharpLinuxText && on.diagnostics.isEmpty)
    }
}
