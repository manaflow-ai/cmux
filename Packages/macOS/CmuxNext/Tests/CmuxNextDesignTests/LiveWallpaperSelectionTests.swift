@testable import CmuxNextDesign
import Testing

/// A live wallpaper is a backdrop selection persisted as `live:<id>`: it round-trips, refuses an
/// empty or spaced id, draws itself (no picture file, no video) and sits in the picker's Live
/// wallpapers group, after Moving wallpapers.
struct LiveWallpaperSelectionTests {
    @Test func liveIDsRoundTrip() throws {
        let selection = try #require(BackdropSelection(id: "live:ink-drift"))
        #expect(selection == .live("ink-drift"))
        #expect(selection.id == "live:ink-drift")
        #expect(selection.liveID == "ink-drift")
        #expect(BackdropSelection.desktop.liveID == nil)
    }

    @Test(arguments: ["live:", "live: ink", "live:ink drift"])
    func malformedLiveIDsAreRefused(id: String) {
        #expect(BackdropSelection(id: id) == nil)
    }

    @Test func aLiveWallpaperHasNoFileAndIsNoVideo() {
        let selection = BackdropSelection.live("ink-drift")
        #expect(!selection.isVideo)
        #expect(selection.imageURL == nil)
        #expect(selection.thumbnailURL == nil)
        #expect(selection.sourceURL == nil)
        #expect(!selection.followsAppearance)
        #expect(selection.pickerCollection?.id == "live")
    }

    /// The app speaks the linked library's ABI: a mismatch empties the first-party set without a
    /// word (#45930 moved the library to 3 while the app still asked for 2), so it fails here.
    @Test func theAppSpeaksTheLinkedLibrarysABI() {
        #expect(LiveWallpaper.linkedABIVersion == LiveWallpaper.abiVersion)
        #expect(!LiveWallpaper.firstParty.isEmpty)
    }

    /// The packed uniform is the size the library writes, so a Frame that grows cannot overrun it.
    @Test func thePackedFrameIsTheLibrarysSize() {
        let colors = LiveWallpaperColors(ink: SIMD3(1, 1, 1), paper: SIMD3(0, 0, 0), accent: SIMD3(0, 0, 1), dark: true)
        #expect(LiveWallpaperFrame(colors: colors).packed().count == LiveWallpaperFrame.floats)
        #expect(LiveWallpaperFrame.floats >= 36)
    }

    /// The catalog lists the first-party set last, each as `live:<id>`.
    @Test func theCatalogEndsWithTheFirstPartySet() {
        let choices = LiveWallpaper.choices
        #expect(choices.map(\.id) == LiveWallpaper.firstParty.map { "live:\($0.id)" })
        #expect(choices.allSatisfy { $0.pickerCollection?.id == "live" })
    }
}
