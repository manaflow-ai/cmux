import Foundation
import Testing
@testable import CmuxNextDaemon

struct WorkspaceMetadataResultTests {
    @Test func decodesKeepAwakeFromMetadataReplies() throws {
        let line = #"{
            "workspace": 7,
            "key": "work",
            "color": null,
            "icon": null,
            "title": null,
            "pinned": false,
            "marked_unread": false,
            "keep_awake": true,
            "workspace_revision": 3,
            "changed": true,
            "replayed": false
        }"#
        let result = try JSONDecoder().decode(WorkspaceMetadataResult.self, from: Data(line.utf8))
        #expect(result.keepAwake == true)
    }
}
