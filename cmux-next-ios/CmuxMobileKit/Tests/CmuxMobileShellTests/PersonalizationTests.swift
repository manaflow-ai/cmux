#if os(iOS)
import Foundation
import Testing
@testable import CmuxMobileDesign

/// Settings > Personalization: "Match my Mac" is the default and draws the
/// matched Mac's stored look; the phone's own choice wins over every Mac
/// until it is "Match my Mac" again; the default theme with no picture is the
/// built-in neutral look; the choice persists.
@MainActor
@Suite(.serialized) struct PersonalizationTests {
    private func scratch() -> (CmuxMobileAppearanceDisk, CmuxMobileAppearance, UserDefaults) {
        let name = "PersonalizationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        defaults.removePersistentDomain(forName: name)
        let disk = CmuxMobileAppearanceDisk(root: FileManager.default.temporaryDirectory.appendingPathComponent(name), defaults: defaults)
        return (disk, CmuxMobileAppearance(accentTheme: CmuxMobileAccentTheme(defaults: defaults), disk: disk), defaults)
    }

    private func macSnapshot() -> CmuxMobileAppearanceSnapshot {
        CmuxMobileAppearanceSnapshot(revision: 1,
                                     theme: .init(dark: .init(name: "Nord", input: CmuxMobileThemeCatalog.nordInput),
                                                  light: .init(name: "Nord", input: CmuxMobileThemeCatalog.nordInput)),
                                     accent: "blue")
    }

    @Test func matchMyMacIsTheDefault() {
        let (disk, appearance, _) = scratch()
        #expect(appearance.personalization.mode == .matchMac)
        disk.store(macSnapshot(), macID: "mac-a")
        appearance.loadAtLaunch()
        #expect(appearance.source == .mac("mac-a"))
        #expect(appearance.token(.bg).dark.hex == "#2E3440")
    }

    @Test func thePhonesChoiceWinsOverTheMac() {
        let (disk, appearance, defaults) = scratch()
        disk.store(macSnapshot(), macID: "mac-a")
        appearance.loadAtLaunch()
        var choice = CmuxMobilePersonalization()
        choice.mode = .phone
        choice.theme = "catppuccin"
        choice.accent = "magenta"
        choice.chromeStyle = "two-tone"
        appearance.personalization = choice
        #expect(appearance.source == .phone)
        #expect(appearance.token(.bg).dark.hex == "#1E1E2E")
        #expect(appearance.token(.bg).light.hex == "#EFF1F5")
        #expect(appearance.token(.sidebarShade).dark.alpha > 0)
        // The Mac changes its look meanwhile: stored, not shown.
        var changed = macSnapshot()
        changed.accent = "red"
        disk.store(changed, macID: "mac-a")
        appearance.macSnapshotChanged(macID: "mac-a")
        #expect(appearance.source == .phone)
        #expect(appearance.token(.bg).dark.hex == "#1E1E2E")
        // Persisted: a relaunch draws the phone's choice.
        #expect(CmuxMobilePersonalization.load(defaults) == choice)
        let relaunched = CmuxMobileAppearance(accentTheme: CmuxMobileAccentTheme(defaults: defaults), disk: disk)
        relaunched.loadAtLaunch()
        #expect(relaunched.source == .phone)
        // Back to the Mac: its latest stored look.
        choice.mode = .matchMac
        appearance.personalization = choice
        #expect(appearance.source == .mac("mac-a"))
        #expect(appearance.token(.bg).dark.hex == "#2E3440")
    }

    @Test func theDefaultThemeIsTheNeutralLook() {
        let (_, appearance, _) = scratch()
        var choice = CmuxMobilePersonalization()
        choice.mode = .phone
        appearance.personalization = choice
        #expect(!appearance.isThemed)
        #expect(appearance.source == .phone)
        #expect(appearance.token(.bg).dark.hex == "#000000")
    }

    @Test func aPictureFromPhotosIsTheBackdrop() throws {
        let (disk, appearance, _) = scratch()
        let data = Data((0..<2048).map { UInt8($0 % 199) })
        let sha = try #require(disk.storePhoneImage(data))
        var choice = CmuxMobilePersonalization()
        choice.mode = .phone
        choice.background = sha
        choice.backgroundOpacity = 0.6
        choice.backgroundBlur = 8
        appearance.personalization = choice
        #expect(appearance.backdrop?.sha256 == sha)
        #expect(appearance.backdrop?.opacity == 0.6)
        #expect(appearance.backdrop?.blur == 8)
        // A second pick replaces the first (one picture kept for the phone).
        let other = try #require(disk.storePhoneImage(Data("other".utf8)))
        #expect(disk.phoneImageURL(sha256: sha) == nil)
        #expect(disk.phoneImageURL(sha256: other) != nil)
    }
}
#endif
