import Foundation
import Testing

@testable import CMUXMobileCore

struct MobileStateSyncFrameCodingTests {
    private var workspace: WorkspaceSyncRecord {
        WorkspaceSyncRecord(
            id: "ws-1",
            windowID: "win-1",
            title: "build",
            currentDirectory: "/repo",
            isSelected: true,
            isPinned: false,
            groupID: "grp-1",
            preview: "tests passed",
            previewAt: 1_700_000_000,
            lastActivityAt: 1_700_000_001,
            hasUnread: true,
            sortIndex: 3,
            terminals: [
                WorkspaceSyncRecord.Terminal(
                    id: "t-1",
                    title: "zsh",
                    currentDirectory: "/repo",
                    isReady: true,
                    isFocused: false
                )
            ],
            surfaces: [
                WorkspaceSyncRecord.Surface(
                    surfaceID: "surface-future",
                    kind: "simulator",
                    title: "iPhone 17 Pro",
                    filePath: nil
                ),
                WorkspaceSyncRecord.Surface(
                    surfaceID: "surface-todo",
                    kind: MobileSurfaceKind.todo.rawValue,
                    title: "Todo",
                    filePath: nil,
                    todo: MobileTodoSnapshot(
                        status: .needsAttention,
                        statusHidden: false,
                        items: [
                            MobileTodoItem(
                                id: "item-1",
                                text: "Review the renderer",
                                state: .inProgress,
                                origin: .agent
                            ),
                        ]
                    )
                )
            ]
        )
    }

    @Test func workspaceRecordUsesLegacyWireKeys() throws {
        let object = try MobileSyncFrameCoder().jsonObject(from: workspace)
        #expect(object["id"] as? String == "ws-1")
        #expect(object["window_id"] as? String == "win-1")
        #expect(object["current_directory"] as? String == "/repo")
        #expect(object["is_selected"] as? Bool == true)
        #expect(object["is_pinned"] as? Bool == false)
        #expect(object["group_id"] as? String == "grp-1")
        #expect(object["preview_at"] as? Double == 1_700_000_000)
        #expect(object["last_activity_at"] as? Double == 1_700_000_001)
        #expect(object["has_unread"] as? Bool == true)
        #expect(object["sort_index"] as? Int == 3)
        let terminals = object["terminals"] as? [[String: Any]]
        #expect(terminals?.first?["is_ready"] as? Bool == true)
        #expect(terminals?.first?["is_focused"] as? Bool == false)
        let surfaces = object["surfaces"] as? [[String: Any]]
        #expect(surfaces?.first?["surface_id"] as? String == "surface-future")
        #expect(surfaces?.first?["kind"] as? String == "simulator")
        #expect(surfaces?.first?["file_path"] == nil)
        let todo = surfaces?[1]["todo"] as? [String: Any]
        #expect(todo?["status"] as? String == "needs-attention")
        #expect(todo?["status_hidden"] as? Bool == false)
        let items = todo?["items"] as? [[String: Any]]
        #expect(items?.first?["id"] as? String == "item-1")
        #expect(items?.first?["state"] as? String == "in_progress")
        #expect(items?.first?["origin"] as? String == "agent")
    }

    @Test func mobileSurfaceKindPreservesUnknownRawValues() throws {
        let kind = MobileSurfaceKind(rawValue: "simulator")
        let data = try JSONEncoder().encode(kind)
        #expect(String(decoding: data, as: UTF8.self) == #""simulator""#)
        #expect(try JSONDecoder().decode(MobileSurfaceKind.self, from: data) == kind)
    }

    @Test func workspaceRecordWithoutSurfacesDecodesAndReencodesWithoutTheField() throws {
        let json = #"{"id":"ws-old","title":"old","is_selected":false,"is_pinned":false,"last_activity_at":1,"has_unread":false,"sort_index":0,"terminals":[]}"#
        let decoded = try MobileSyncFrameCoder().decode(
            WorkspaceSyncRecord.self,
            fromJSONString: json
        )
        #expect(decoded.surfaces == nil)
        let object = try MobileSyncFrameCoder().jsonObject(from: decoded)
        #expect(object["surfaces"] == nil)
    }

    @Test func workspaceRecordRoundTripsSurfaceInventory() throws {
        let decoded = try JSONDecoder().decode(
            WorkspaceSyncRecord.self,
            from: JSONEncoder().encode(workspace)
        )
        #expect(decoded == workspace)
        #expect(decoded.surfaces?.first?.kind == "simulator")
        #expect(decoded.surfaces?[1].todo?.status == .needsAttention)
        #expect(decoded.surfaces?[1].todo?.items.first?.state == .inProgress)
    }

    @Test func deltaEventRoundTripsThroughJSONObject() throws {
        let event = MobileSyncDeltaEvent(
            epoch: "e1",
            collection: .workspaces,
            fromRev: 41,
            toRev: 42,
            records: [workspace],
            removedIDs: ["ws-9"]
        )
        let object = try MobileSyncFrameCoder().jsonObject(from: event)
        #expect(object["from_rev"] as? UInt64 == 41)
        #expect(object["to_rev"] as? UInt64 == 42)
        #expect(object["removed_ids"] as? [String] == ["ws-9"])

        let decoded = try MobileSyncFrameCoder().decode(
            MobileSyncDeltaEvent<WorkspaceSyncRecord>.self,
            fromJSONObject: object
        )
        #expect(decoded == event)
    }

    @Test func deltaHeaderDecodesCollectionFirst() throws {
        let event = MobileSyncDeltaEvent<GroupSyncRecord>(
            epoch: "e1",
            collection: .groups,
            fromRev: 1,
            toRev: 2,
            records: [],
            removedIDs: []
        )
        let object = try MobileSyncFrameCoder().jsonObject(from: event)
        let header = try MobileSyncFrameCoder().decode(MobileSyncDeltaEventHeader.self, fromJSONObject: object)
        #expect(header.collection == .groups)
    }

    @Test func fetchRequestDecodesFromUntypedParams() throws {
        let params: [String: Any] = [
            "collections": [
                ["id": "workspaces", "epoch": "e1", "rev": 12],
                ["id": "groups"],
                ["id": "future_collection", "epoch": "e1", "rev": 3],
            ]
        ]
        let request = try MobileSyncFrameCoder().decode(MobileSyncFetchRequest.self, fromJSONObject: params)
        #expect(request.collections.count == 3)
        #expect(request.collections[0].cursor == MobileSyncCursor(epoch: "e1", rev: 12))
        #expect(request.collections[1].cursor == nil)
        #expect(request.collections[2].id == MobileSyncCollectionID(rawValue: "future_collection"))
    }

    @Test func fetchResponseOmitsAbsentSections() throws {
        let response = MobileSyncFetchResponse(
            epoch: "e1",
            workspaces: MobileSyncCollectionPayload(
                mode: .snapshot,
                rev: 4,
                fromRev: nil,
                records: [workspace],
                removedIDs: []
            ),
            groups: nil
        )
        let object = try MobileSyncFrameCoder().jsonObject(from: response)
        #expect(object["groups"] == nil)
        let section = object["workspaces"] as? [String: Any]
        #expect(section?["mode"] as? String == "snapshot")
        #expect(section?["from_rev"] == nil)

        let decoded = try MobileSyncFrameCoder().decode(MobileSyncFetchResponse.self, fromJSONObject: object)
        #expect(decoded == response)
    }

    @Test func unknownCollectionIDDecodesInsteadOfFailing() throws {
        let decoded = try MobileSyncFrameCoder().decode(
            MobileSyncDeltaEventHeader.self,
            fromJSONString: #"{"collection":"records_from_the_future"}"#
        )
        #expect(decoded.collection.rawValue == "records_from_the_future")
    }
}
