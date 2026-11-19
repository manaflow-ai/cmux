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

    /// The catalog lists the first-party set last, each as `live:<id>`.
    @Test func theCatalogEndsWithTheFirstPartySet() {
        let choices = LiveWallpaper.choices
        #expect(choices.map(\.id) == LiveWallpaper.firstParty.map { "live:\($0.id)" })
        #expect(choices.allSatisfy { $0.pickerCollection?.id == "live" })
    }
}
