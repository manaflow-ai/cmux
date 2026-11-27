@testable import CmuxNextDesign
import Foundation
import Testing
import CmuxNextDesignTokens

/// Browse more art (cx-t2x.8): a search asks every open-access collection and keeps only the
/// public-domain works with an image on that collection's own hosts (answers recorded from the
/// live APIs on 2026-10-12, trimmed).
@Suite struct MuseumArtSearchTests {
    nonisolated static let artInstitute = """
    {"config": {"iiif_url": "https://www.artic.edu/iiif/2"}, "data": [
      {"id": 154235, "title": "The Girl by the Window", "artist_title": "Edvard Munch", "date_display": "1893",
       "image_id": "d7df2633-3b40-f570-c906-211503a37cde", "is_public_domain": true},
      {"id": 999, "title": "Still Under Copyright", "artist_title": "Someone", "date_display": "1961",
       "image_id": "aaaa", "is_public_domain": false},
      {"id": 1000, "title": "No Image", "artist_title": "Someone", "date_display": "1800", "image_id": null, "is_public_domain": true}
    ]}
    """
    nonisolated static let cleveland = """
    {"data": [
      {"id": 149108, "title": "Scenes of Witchcraft: Night", "creation_date": "c. 1645–49", "share_license_status": "CC0",
       "creators": [{"description": "Salvator Rosa (Italian, 1615–1673)"}], "url": "https://clevelandart.org/art/1977.37.4",
       "images": {"web": {"url": "https://openaccess-cdn.clevelandart.org/1977.37.4/1977.37.4_web.jpg"},
                  "print": {"url": "https://openaccess-cdn.clevelandart.org/1977.37.4/1977.37.4_print.jpg"}}},
      {"id": 2, "title": "Copyrighted", "share_license_status": "Copyrighted", "url": "https://clevelandart.org/art/2",
       "images": {"web": {"url": "https://openaccess-cdn.clevelandart.org/2/2_web.jpg"}}},
      {"id": 3, "title": "Elsewhere", "share_license_status": "CC0", "url": "https://clevelandart.org/art/3",
       "images": {"web": {"url": "https://example.com/3.jpg"}}}
    ]}
    """
    nonisolated static let commons = """
    {"query": {"pages": {
      "1": {"pageid": 1, "index": 1, "title": "File:Van Gogh - Starry Night - Google Art Project.jpg", "imageinfo": [{
        "mime": "image/jpeg",
        "thumburl": "https://thumb.wikimedia.org/wikipedia/commons/thumb/e/ea/Starry.jpg/3840px-Starry.jpg?utm_content=thumbnail",
        "url": "https://upload.wikimedia.org/wikipedia/commons/e/ea/Starry.jpg",
        "descriptionurl": "https://commons.wikimedia.org/wiki/File:Starry.jpg",
        "extmetadata": {"LicenseShortName": {"value": "Public domain"},
          "Artist": {"value": "<bdi><a href=\\"https://en.wikipedia.org/wiki/Vincent_van_Gogh\\">Vincent van Gogh</a></bdi>"},
          "ObjectName": {"value": "<i>The Starry Night</i>"},
          "DateTimeOriginal": {"value": "1889<div style=\\"display: none;\\">date QS:P571,+1889</div>"}}}]},
      "3": {"pageid": 3, "index": 2, "title": "File:Small night.jpg", "imageinfo": [{
        "mime": "image/jpeg",
        "thumburl": "https://upload.wikimedia.org/wikipedia/commons/6/66/Small_night.jpg?utm_content=thumbnail_unscaled",
        "url": "https://upload.wikimedia.org/wikipedia/commons/6/66/Small_night.jpg",
        "descriptionurl": "https://commons.wikimedia.org/wiki/File:Small_night.jpg",
        "extmetadata": {"LicenseShortName": {"value": "Public domain"}}}]},
      "2": {"pageid": 2, "index": 3, "title": "File:Recent photo.jpg", "imageinfo": [{
        "mime": "image/jpeg", "thumburl": "https://upload.wikimedia.org/x/2400px-p.jpg",
        "descriptionurl": "https://commons.wikimedia.org/wiki/File:Recent_photo.jpg",
        "extmetadata": {"LicenseShortName": {"value": "CC BY-SA 4.0"}}}]}
    }}}
    """

    nonisolated static func answers(failing: Set<String> = []) -> @Sendable (URL) async throws -> Data {
        { url in
            let host = url.host ?? ""
            if failing.contains(host) { throw URLError(.timedOut) }
            switch host {
            case "api.artic.edu": return Data(artInstitute.utf8)
            case "openaccess-api.clevelandart.org": return Data(cleveland.utf8)
            case "commons.wikimedia.org": return Data(commons.utf8)
            default: return Data("image of \(url.lastPathComponent)".utf8)
            }
        }
    }

    @Test func aSearchKeepsOnlyPublicDomainWorksWithTheirImages() async throws {
        let results = await MuseumArtSearch(fetch: Self.answers()).search("night")
        #expect(results.map(\.key) == ["aic:154235", "cleveland:149108", "commons:1", "commons:3"])
        let munch = try #require(results.first)
        #expect(munch.title == "The Girl by the Window" && munch.artist == "Edvard Munch" && munch.date == "1893")
        #expect(munch.image.absoluteString == "https://www.artic.edu/iiif/2/d7df2633-3b40-f570-c906-211503a37cde/full/1686,/0/default.jpg")
        #expect(results[1].artist == "Salvator Rosa")
        #expect(results[1].image.lastPathComponent == "1977.37.4_print.jpg")
        let starry = results[2]
        #expect(starry.title == "The Starry Night" && starry.artist == "Vincent van Gogh" && starry.date == "1889")
        // Commons answers its nearest standard width (or the original) and serves only standard
        // thumbnail widths, so the grid asks for 500 pixels either way.
        #expect(starry.thumbnail.absoluteString == "https://thumb.wikimedia.org/wikipedia/commons/thumb/e/ea/Starry.jpg/500px-Starry.jpg?utm_content=thumbnail")
        #expect(results[3].thumbnail.absoluteString == "https://upload.wikimedia.org/wikipedia/commons/thumb/6/66/Small_night.jpg/500px-Small_night.jpg")
        #expect(results[3].title == "Small night")
        #expect(starry.page.absoluteString == "https://commons.wikimedia.org/wiki/File:Starry.jpg")
    }

    @Test func aCollectionThatFailsLeavesTheOthers() async {
        let results = await MuseumArtSearch(fetch: Self.answers(failing: ["api.artic.edu"])).search("night")
        #expect(results.map(\.key) == ["cleveland:149108", "commons:1", "commons:3"])
        #expect(await MuseumArtSearch(fetch: Self.answers()).search("   ").isEmpty)
    }

    @Test func onlyAResultsOwnImagesAreFetched() async throws {
        let search = MuseumArtSearch(fetch: Self.answers())
        let munch = try #require(await search.search("night").first)
        #expect(await search.image(munch.thumbnail, of: munch) != nil)
        #expect(await search.image(URL(string: "https://example.com/secret")!, of: munch) == nil)
        #expect(await search.image(URL(fileURLWithPath: "/etc/hosts"), of: munch) == nil)
    }
}
