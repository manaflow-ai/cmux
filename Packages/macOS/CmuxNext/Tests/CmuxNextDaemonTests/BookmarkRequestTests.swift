@testable import CmuxNextDaemon
import Foundation
import Testing

/// Every bookmarks-v1 write carries the exactly-once key (`origin`,
/// `mutation_id`), as the #16174 owner requires; the id field is `bookmark`.
@Suite struct BookmarkRequestTests {
    private let key = MutationIdentity(origin: "o", mutationID: "m")

    private func object<R: DaemonRequest>(_ request: R) throws -> [String: JSONValue] {
        let data = try WireCoding.encodeRequest(request, id: 3)
        guard case .object(let object) = try JSONDecoder().decode(JSONValue.self, from: data) else {
            throw DaemonError.malformedResponse("not an object")
        }
        return object
    }

    private func expectKey(_ json: [String: JSONValue], _ command: String) {
        #expect(json["cmd"] == .string(command))
        #expect(json["origin"] == .string("o") && json["mutation_id"] == .string("m"), "\(command)")
    }

    @Test func everyWriteCarriesTheMutationKey() throws {
        let create = try object(CreateBookmarkRequest(bookmark: "bm_1", browserProfileID: "default", parent: "bar", index: nil,
                                                      kind: "url", title: "A", url: "https://a.com", faviconKey: nil,
                                                      sourceKey: nil, createdMs: 1, mutation: key))
        expectKey(create, "create-bookmark")
        #expect(create["bookmark"] == .string("bm_1"))
        expectKey(try object(UpdateBookmarkRequest(bookmark: "bm_1", title: "B", mutation: key)), "update-bookmark")
        expectKey(try object(MoveBookmarkRequest(bookmark: "bm_1", parent: "other", index: 0, mutation: key)), "move-bookmark")
        expectKey(try object(DeleteBookmarkRequest(bookmark: "bm_1", mutation: key)), "delete-bookmark")
        expectKey(try object(ImportBookmarksRequest(browserProfileID: "default", parent: "bar", index: nil, sourceKey: "s",
                                                    replace: true, nodes: [], mutation: key)), "import-bookmarks")
    }

    @Test func resultsDecodeReplayed() throws {
        let line = Data(#"{"bookmark":{"id":"bm_1","browser_profile_id":"default","parent":"bar","kind":"url","index":0,"title":"A","created_ms":1},"changed":false,"replayed":true}"#.utf8)
        let result = try JSONDecoder().decode(BookmarkResult.self, from: line)
        #expect(result.replayed == true && result.bookmark.id == "bm_1")
    }
}
