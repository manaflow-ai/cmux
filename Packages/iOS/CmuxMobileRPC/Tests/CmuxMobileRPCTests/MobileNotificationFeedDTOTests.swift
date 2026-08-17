import CmuxMobileRPC
import Foundation
import Testing

@Suite("Notification feed RPC DTOs")
struct MobileNotificationFeedDTOTests {
    @Test("List response decodes every navigation and display field")
    func listResponseDecode() throws {
        let data = Data(#"{"revision":17,"notifications":[{"id":"notification-1","workspace_id":"workspace-1","surface_id":"surface-1","title":"Approval needed","subtitle":"Claude Code","body":"Allow the command?","created_at":1721000000.25,"is_read":false,"retargets_to_live_surface_owner":true,"workspace_title":"cmux","surface_title":"agent"}]}"#.utf8)

        let response = try MobileNotificationFeedListResponse.decode(data)
        let item = try #require(response.notifications.first)

        #expect(response.revision == 17)
        #expect(item.id == "notification-1")
        #expect(item.workspaceID == "workspace-1")
        #expect(item.surfaceID == "surface-1")
        #expect(item.title == "Approval needed")
        #expect(item.subtitle == "Claude Code")
        #expect(item.body == "Allow the command?")
        #expect(item.createdAt == Date(timeIntervalSince1970: 1_721_000_000.25))
        #expect(item.isRead == false)
        #expect(item.retargetsToLiveSurfaceOwner)
        #expect(item.workspaceTitle == "cmux")
        #expect(item.surfaceTitle == "agent")
    }

    @Test("Missing retarget provenance stays confined")
    func missingRetargetProvenanceDefaultsToFalse() throws {
        let data = Data(#"{"revision":1,"notifications":[{"id":"notification-1","workspace_id":"workspace-1","title":"Title","body":"Body","created_at":1721000000,"is_read":true}]}"#.utf8)

        let item = try #require(MobileNotificationFeedListResponse.decode(data).notifications.first)

        #expect(!item.retargetsToLiveSurfaceOwner)
    }

    @Test("List response decodes every structured workstream action")
    func workstreamActionsDecode() throws {
        let data = Data(#"{"revision":18,"notifications":[],"workstreams":[{"id":"item-1","workstream_id":"claude-session","workspace_id":"workspace-1","surface_id":"surface-1","source":"claude","kind":"permissionRequest","created_at":"2026-08-09T12:00:00Z","request_id":"request-1","tool_name":"Bash","tool_input":"pwd"},{"id":"item-2","workstream_id":"claude-session","workspace_id":"workspace-1","surface_id":"surface-1","source":"claude","kind":"exitPlan","created_at":"2026-08-09T12:00:01Z","request_id":"request-2","plan":"Ship it","default_mode":"manual"},{"id":"item-3","workstream_id":"claude-session","workspace_id":"workspace-1","surface_id":"surface-1","source":"claude","kind":"question","created_at":"2026-08-09T12:00:02Z","request_id":"request-3","questions":[{"id":"q1","header":"Scope","prompt":"Which targets?","multi_select":true,"options":[{"id":"ios","label":"iOS","description":"Phone app"}]}]}]}"#.utf8)

        let response = try MobileNotificationFeedListResponse.decode(data)

        #expect(response.workstreams.map(\.kind) == ["permissionRequest", "exitPlan", "question"])
        #expect(response.workstreams[0].toolName == "Bash")
        #expect(response.workstreams[1].defaultMode == "manual")
        #expect(response.workstreams[2].questions.first?.multiSelect == true)
        #expect(response.workstreams[2].questions.first?.options.first?.description == "Phone app")
    }

    @Test("Bounded list response decodes only the retained prefix")
    func boundedListResponseDecodeStopsAtCapAndLimitsStrings() throws {
        let data = Data(
            """
            {"revision":17,"notifications":[{"id":"overlong-identity","workspace_id":"workspace","title":"Dropped","body":"Dropped","created_at":1721000000,"is_read":false},{"id":"valid-1","workspace_id":"work-1","surface_id":"surf-1","title":"abcdef","subtitle":"ghijk","body":"lmnopqr","created_at":1721000000.25,"is_read":false,"retargets_to_live_surface_owner":true,"workspace_title":"workspace-title","surface_title":"surface-title"},{"workspace_id":"invalid-trailing-row","title":"Dropped","body":"Missing id","created_at":1721000002,"is_read":false}]}
            """.utf8
        )

        #expect(throws: (any Error).self) {
            _ = try MobileNotificationFeedListResponse.decode(data)
        }
        let response = try MobileNotificationFeedListResponse(
            decodingBounded: data,
            maxNotifications: 1,
            stringLimits: MobileNotificationFeedListStringLimits(
                identifierByteLimit: 8,
                titleByteLimit: 5,
                subtitleByteLimit: 4,
                bodyByteLimit: 6,
                metadataByteLimit: 7
            )
        )

        #expect(response.revision == 17)
        #expect(response.notifications.count == 1)
        let first = try #require(response.notifications.first)
        #expect(first.id == "valid-1")
        #expect(first.workspaceID == "work-1")
        #expect(first.surfaceID == "surf-1")
        #expect(first.title == "abcde")
        #expect(first.subtitle == "ghij")
        #expect(first.body == "lmnopq")
        #expect(first.workspaceTitle == "workspa")
        #expect(first.surfaceTitle == "surface")
        #expect(first.retargetsToLiveSurfaceOwner)
    }

    @Test("Bounded list response limits structured workstream content")
    func boundedWorkstreamDecodeLimitsNestedContent() throws {
        let questions = (0..<20).map { questionIndex in
            [
                "id": "q\(questionIndex)",
                "header": "header-long",
                "prompt": "prompt-long",
                "multi_select": true,
                "options": (0..<40).map { optionIndex in
                    [
                        "id": "o\(optionIndex)",
                        "label": "label-long",
                        "description": "description-long",
                    ] as [String: Any]
                },
            ] as [String: Any]
        }
        let payload: [String: Any] = [
            "revision": 19,
            "notifications": [],
            "workstreams": [[
                "id": "item",
                "workstream_id": "session",
                "workspace_id": "workspace",
                "surface_id": "surface",
                "source": "claude-long",
                "kind": "question-long",
                "created_at": "2026-08-09T12:00:00Z",
                "request_id": "request",
                "tool_name": "tool-long",
                "tool_input": "input-long",
                "plan": "plan-long",
                "default_mode": "manual-long",
                "questions": questions,
            ]],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)

        let response = try MobileNotificationFeedListResponse(
            decodingBounded: data,
            maxNotifications: 1,
            stringLimits: MobileNotificationFeedListStringLimits(
                identifierByteLimit: 9,
                titleByteLimit: 5,
                subtitleByteLimit: 4,
                bodyByteLimit: 6,
                metadataByteLimit: 4
            )
        )

        let item = try #require(response.workstreams.first)
        #expect(item.workspaceID == "workspace")
        #expect(item.surfaceID == "surface")
        #expect(item.source == "clau")
        #expect(item.kind == "ques")
        #expect(item.toolName == "tool")
        #expect(item.toolInput == "input-")
        #expect(item.plan == "plan-l")
        #expect(item.defaultMode == "manu")
        #expect(item.questions.count == 16)
        #expect(item.questions.first?.header == "head")
        #expect(item.questions.first?.prompt == "prompt")
        #expect(item.questions.first?.options.count == 32)
        #expect(item.questions.first?.options.first?.label == "labe")
        #expect(item.questions.first?.options.first?.description == "desc")
    }

    @Test("Revision-only changed event rejects malformed payloads")
    func changedEventDecode() {
        #expect(MobileNotificationFeedChangedEvent.decode(Data(#"{"revision":18}"#.utf8))?.revision == 18)
        #expect(MobileNotificationFeedChangedEvent.decode(Data(#"{"revision":"18"}"#.utf8)) == nil)
    }

    @Test("Read mutation response decodes marked count and revision")
    func mutationResponseDecode() throws {
        let response = try MobileNotificationFeedMutationResponse.decode(
            Data(#"{"marked":3,"revision":21}"#.utf8)
        )

        #expect(response.marked == 3)
        #expect(response.revision == 21)
    }
}
