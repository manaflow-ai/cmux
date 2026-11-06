import CmuxNextFileGrid
import Foundation
import Testing

/// A grid item's identity is its file's path, kept in step with its URL.
@Suite struct FileGridItemIdentityTests {
    @Test func theIdIsThePathAndFollowsTheURL() {
        var item = FileGridItem(url: URL(fileURLWithPath: "/tmp/Screen Shot 1.png"), size: 4, modified: Date(), sourceID: "s")
        #expect(item.id == "/tmp/Screen Shot 1.png")
        item.url = URL(fileURLWithPath: "/tmp/shots/Screen Shot 2.png")
        #expect(item.id == "/tmp/shots/Screen Shot 2.png")
        #expect(item.name == "Screen Shot 2.png")
    }
}
