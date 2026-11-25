@testable import CmuxNextPages
import Foundation
import Testing

/// Gallery Stage (``GalleryStageTabs``): the page a run opens on the gallery server.
struct GalleryStageTabsTests {
    private func parse(_ string: String) throws -> URL { try #require(URL(string: string)) }

    @Test func anEntryOpensItsStageInTheAppHost() throws {
        let gallery = try parse("http://127.0.0.1:4178/")
        let url = GalleryStageTabs.stageURL(gallery: gallery, entry: "agent-pane.composer", variant: "busy")
        #expect(url?.absoluteString == "http://127.0.0.1:4178/gallery/frame.html?entry=agent-pane.composer&variant=busy&host=app")
        let first = GalleryStageTabs.stageURL(gallery: gallery, entry: " pages.diff ", variant: "")
        #expect(first?.absoluteString == "http://127.0.0.1:4178/gallery/frame.html?entry=pages.diff&host=app")
    }

    @Test func noEntryOpensTheGalleryIndex() throws {
        let gallery = try parse("http://127.0.0.1:4178/")
        #expect(GalleryStageTabs.stageURL(gallery: gallery, entry: nil, variant: nil)?.absoluteString == "http://127.0.0.1:4178/gallery/")
    }

    @Test func onlyALoopbackServerServesAStage() throws {
        #expect(GalleryStageTabs.stageURL(gallery: try parse("http://10.0.0.2:4178/"), entry: "x", variant: nil) == nil)
        #expect(GalleryStageTabs.stageURL(gallery: try parse("https://127.0.0.1:4178/"), entry: "x", variant: nil) == nil)
    }
}
