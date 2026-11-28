@testable import CmuxNextSidebar
import Foundation
import Testing

/// The mirror answers `project` as splices of what it sent last (cmux-layout-reducer `sidebar_doc::view_splice`); the
/// app applies them to the projection it keeps (`SidebarDocWire.KeptProjection`). After every change the kept
/// projection equals the one a new mirror answers in full, and a change that keeps the live list sends none.
@MainActor
struct SidebarMirrorSpliceTests {
    private static let live = (0 ..< 40).map { SidebarDocWorkspaceRef(sessionID: "mini", workspaceID: "w\($0)") }
        + [SidebarDocWorkspaceRef(sessionID: "mini", workspaceID: "unplaced")]

    /// 39 workspaces in groups of 3 over the machine section and a custom one (w39 loose in Pinned).
    private static func document(revision: Int, label: String? = nil) -> Data {
        var items: [[String: Any]] = []
        for n in 0 ..< 39 {
            let section = n % 2 == 0 ? "sec_m_mini" : "sec_custom"
            let group = "g\(n / 3)_\(section)"
            if n % 3 == 0 || !items.contains(where: { $0["id"] as? String == group }) {
                items.append(["id": group, "section": section, "order": String(format: "a%04d", n),
                              "body": ["type": "group", "name": "Group \(n / 3)"]])
            }
            var item: [String: Any] = ["id": "itm_w_mini_w\(n)", "section": section, "parent": group, "order": String(format: "b%04d", n),
                                       "body": ["type": "workspace", "ref": ["session_id": "mini", "workspace_id": "w\(n)"]]]
            if n == 7, let label { item["extra"] = ["label": label] }
            items.append(item)
        }
        items.append(["id": "itm_w_mini_w39", "section": "sec_pinned", "order": "a",
                      "body": ["type": "workspace", "ref": ["session_id": "mini", "workspace_id": "w39"]]])
        let sections: [[String: Any]] = [
            ["id": "sec_pinned", "kind": ["type": "pinned"], "order": "a", "keeps_closed": true],
            ["id": "sec_custom", "kind": ["type": "custom"], "title": "Custom", "order": "b"],
            ["id": "sec_m_mini", "kind": ["type": "machine", "session_id": "mini"], "order": "c"],
        ]
        let document: [String: Any] = ["revision": String(revision), "sections": sections, "items": items]
        return (try? JSONSerialization.data(withJSONObject: document)) ?? Data()
    }

    /// The projection a mirror that holds nothing answers for `document`.
    private static func full(_ document: Data, live: [SidebarDocWorkspaceRef]) throws -> SidebarDocProjection {
        let mirror = SidebarMirror()
        try #require(mirror.load(document) != nil)
        let wire = try #require(mirror.projection(SidebarViewRequest(live: live)))
        return SidebarDocProjection(wire: wire, revision: 1)
    }

    @Test func theSplicedProjectionEqualsAFullOneAfterEachChange() throws {
        let mirror = SidebarMirror()
        try #require(mirror.load(Self.document(revision: 1)) != nil)
        var live = Self.live
        let first = try #require(mirror.projection(SidebarViewRequest(live: live)))
        #expect(SidebarDocProjection(wire: first, revision: 1) == (try Self.full(Self.document(revision: 1), live: live)))

        // A rename echoed by the daemon: the live list is the one sent, so the request carries none.
        let item: [String: Any] = ["id": "itm_w_mini_w7", "section": "sec_custom", "parent": "g2_sec_custom", "order": "b0007",
                                   "body": ["type": "workspace", "ref": ["session_id": "mini", "workspace_id": "w7"]],
                                   "extra": ["label": "renamed"]]
        let batch: [String: Any] = ["changes": [
            ["resource": "sidebar_doc", "value": ["revision": "2", "previous_revision": "1"]],
            ["kind": "state_upsert", "resource": "sidebar_item", "id": "itm_w_mini_w7", "value": item],
        ]]
        #expect(mirror.apply(batch: try JSONSerialization.data(withJSONObject: batch)) == .applied(revision: 2))
        let renamed = try #require(mirror.projection(SidebarViewRequest(live: live)))
        #expect(SidebarDocProjection(wire: renamed, revision: 1)
            == (try Self.full(Self.document(revision: 2, label: "renamed"), live: live)))

        // A workspace closes and another opens unplaced: the live list goes again.
        live.removeAll { $0.workspaceID == "w4" }
        live.append(SidebarDocWorkspaceRef(sessionID: "mini", workspaceID: "opened"))
        let changed = try #require(mirror.projection(SidebarViewRequest(live: live)))
        #expect(SidebarDocProjection(wire: changed, revision: 1)
            == (try Self.full(Self.document(revision: 2, label: "renamed"), live: live)))
    }
}
