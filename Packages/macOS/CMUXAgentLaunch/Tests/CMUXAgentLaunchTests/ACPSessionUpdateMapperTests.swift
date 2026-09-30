import Foundation
import Testing
@testable import CMUXAgentLaunch

@Suite("ACP session update mapper")
struct ACPSessionUpdateMapperTests {
    private let mapper = ACPSessionUpdateMapper(sessionID: "session-1")

    private func update(
        _ mapping: ACPSessionUpdateMapper.Mapping
    ) throws -> [String: Any] {
        guard case .update(let value) = mapping else {
            Issue.record("Expected an update")
            throw TestError.expectedUpdate
        }
        return value
    }

    private func skipped(
        _ mapping: ACPSessionUpdateMapper.Mapping,
        reason: String
    ) {
        guard case .skipped(let actual) = mapping else {
            Issue.record("Expected skipped(\(reason))")
            return
        }
        #expect(actual == reason)
    }

    private enum TestError: Error { case expectedUpdate }

    @Test("Maps agent prose to an agent message chunk")
    func mapsAgentProse() throws {
        let value = try update(mapper.mapping(for: [
            "role": "agent",
            "id": "message-1",
            "kind": ["type": "prose", "text": "Hello"],
        ]))
        #expect(value["sessionUpdate"] as? String == "agent_message_chunk")
        #expect((value["content"] as? [String: Any])?["text"] as? String == "Hello")
    }

    @Test("Maps user prose to a user message chunk")
    func mapsUserProse() throws {
        let value = try update(mapper.mapping(for: [
            "role": "user",
            "kind": ["type": "prose", "text": "Please continue"],
        ]))
        #expect(value["sessionUpdate"] as? String == "user_message_chunk")
        #expect((value["content"] as? [String: Any])?["type"] as? String == "text")
        #expect((value["content"] as? [String: Any])?["text"] as? String == "Please continue")
    }

    @Test("Maps thought text to an agent thought chunk")
    func mapsThought() throws {
        let value = try update(mapper.mapping(for: [
            "kind": ["type": "thought", "text": "I should inspect the file"],
        ]))
        #expect(value["sessionUpdate"] as? String == "agent_thought_chunk")
        #expect((value["content"] as? [String: Any])?["text"] as? String == "I should inspect the file")
    }

    @Test("Maps a tool use with status, locations, output, and raw input")
    func mapsToolUse() throws {
        let value = try update(mapper.mapping(for: [
            "seq": 12,
            "kind": [
                "type": "tool_use",
                "tool_name": "grep",
                "summary": "Search sources",
                "status": "succeeded",
                "output": "match",
                // Absolute, because ACP locations must be. The two tests
                // below own what happens to a relative path.
                "referenced_paths": ["/repo/Sources/App.swift"],
                "input_detail": "pattern=ACP",
            ],
        ]))
        #expect(value["sessionUpdate"] as? String == "tool_call")
        #expect(value["toolCallId"] as? String == "seq-12")
        #expect(value["title"] as? String == "Search sources")
        #expect(value["kind"] as? String == "search")
        #expect(value["status"] as? String == "completed")
        #expect((value["locations"] as? [[String: Any]])?.first?["path"] as? String == "/repo/Sources/App.swift")
        #expect((value["rawInput"] as? [String: Any])?["detail"] as? String == "pattern=ACP")
        let content = try #require((value["content"] as? [[String: Any]])?.first)
        #expect(content["type"] as? String == "content")
        #expect((content["content"] as? [String: Any])?["text"] as? String == "match")
    }

    @Test("Resolves relative tool locations against the session cwd")
    func resolvesRelativeToolLocations() throws {
        let mapper = ACPSessionUpdateMapper(sessionID: "session-1", cwd: "/tmp/session")
        let value = try update(mapper.mapping(for: [
            "kind": [
                "type": "tool_use",
                "referenced_paths": ["Sources/App.swift", "/opt/absolute.swift"],
            ],
        ]))
        let locations = try #require(value["locations"] as? [[String: Any]])
        #expect(locations.map { $0["path"] as? String } == [
            "/tmp/session/Sources/App.swift",
            "/opt/absolute.swift",
        ])
    }

    @Test("Drops relative tool locations when the session cwd is unknown")
    func dropsRelativeToolLocationsWithoutCWD() throws {
        let value = try update(mapper.mapping(for: [
            "kind": [
                "type": "tool_use",
                "referenced_paths": ["Sources/App.swift"],
            ],
        ]))
        #expect(value.keys.contains("locations") == false)
    }

    @Test("Maps a terminal event to an execute tool call")
    func mapsTerminal() throws {
        let value = try update(mapper.mapping(for: [
            "id": "terminal-1",
            "kind": [
                "type": "terminal",
                "command": "swift test",
                "is_running": false,
                "exit_code": 0,
                "output": "All tests passed",
            ],
        ]))
        #expect(value["toolCallId"] as? String == "terminal-1")
        #expect(value["sessionUpdate"] as? String == "tool_call")
        #expect(value["title"] as? String == "swift test")
        #expect(value["kind"] as? String == "execute")
        #expect(value["status"] as? String == "completed")
        #expect((value["rawInput"] as? [String: Any])?["command"] as? String == "swift test")
        let content = try #require((value["content"] as? [[String: Any]])?.first)
        #expect((content["content"] as? [String: Any])?["text"] as? String == "All tests passed")
    }

    @Test("Maps a file edit to a completed edit tool call")
    func mapsFileEdit() throws {
        let value = try update(mapper.mapping(for: [
            "kind": [
                "type": "file_edit",
                "file_path": "/tmp/App.swift",
                "operation": "delete",
                "unified_diff": "@@ -1 +0,0 @@",
                "additions": 0,
                "deletions": 1,
            ],
        ]))
        #expect(value["kind"] as? String == "delete")
        #expect(value["title"] as? String == "delete /tmp/App.swift")
        #expect(value["status"] as? String == "completed")
        #expect((value["locations"] as? [[String: Any]])?.first?["path"] as? String == "/tmp/App.swift")
        #expect((value["rawInput"] as? [String: Any])?["deletions"] as? Int == 1)
        #expect((value["rawInput"] as? [String: Any])?["additions"] as? Int == 0)
        let content = try #require((value["content"] as? [[String: Any]])?.first)
        #expect((content["content"] as? [String: Any])?["text"] as? String == "@@ -1 +0,0 @@")
    }

    @Test("Maps a path attachment to a resource link")
    func mapsPathAttachment() throws {
        let value = try update(mapper.mapping(for: [
            "kind": [
                "type": "attachment",
                "display_name": "Screenshot",
                "host_path": "/tmp/screenshot.png",
                "media": "image",
            ],
        ]))
        let content = try #require(value["content"] as? [String: Any])
        #expect(content["type"] as? String == "resource_link")
        #expect(content["uri"] as? String == "file:///tmp/screenshot.png")
        #expect(value["sessionUpdate"] as? String == "agent_message_chunk")
        #expect(content["name"] as? String == "Screenshot")
        // An image attachment carries no media type. `ChatAttachment` records
        // only image-or-file, so the link omits `mimeType` rather than send
        // `"image/*"`, which is a wildcard pattern and not a media type.
        #expect(content.keys.contains("mimeType") == false)
    }

    @Test("Maps a named attachment without a path to text")
    func mapsNamedAttachment() throws {
        let value = try update(mapper.mapping(for: [
            "role": "user",
            "kind": ["type": "attachment", "display_name": "notes.txt"],
        ]))
        #expect(value["sessionUpdate"] as? String == "user_message_chunk")
        #expect((value["content"] as? [String: Any])?["text"] as? String == "[attachment: notes.txt]")
    }

    @Test("Replays updates in source order and counts dropped events")
    func replaysInOrderAndCountsDrops() {
        let replay = mapper.replay(messages: [
            ["kind": ["type": "prose", "text": "first"]],
            ["kind": ["type": "permission_request"]],
            ["kind": ["type": "status"]],
            ["kind": ["type": "prose", "text": "second"]],
        ])
        #expect(replay.notifications.count == 2)
        #expect(replay.notifications.first?["sessionId"] as? String == "session-1")
        let texts = replay.notifications.compactMap { notification in
            let update = notification["update"] as? [String: Any]
            let content = update?["content"] as? [String: Any]
            return content?["text"] as? String
        }
        #expect(texts == ["first", "second"])
        #expect(replay.skipped["permission_request"] == 1)
        #expect(replay.skipped["status"] == 1)
    }

    @Test("Skips empty prose, thoughts, and attachments")
    func skipsEmptyEvents() {
        skipped(mapper.mapping(for: ["kind": ["type": "prose", "text": " \n"]]), reason: "empty")
        skipped(mapper.mapping(for: ["kind": ["type": "thought", "text": "\t"]]), reason: "empty")
        skipped(mapper.mapping(for: ["kind": ["type": "attachment"]]), reason: "empty")
    }

    @Test("Skips live permission requests")
    func skipsPermissionRequests() {
        skipped(mapper.mapping(for: ["kind": ["type": "permission_request"]]), reason: "permission_request")
    }

    @Test("Skips live questions")
    func skipsQuestions() {
        skipped(mapper.mapping(for: ["kind": ["type": "question"]]), reason: "question")
    }

    @Test("Skips lifecycle status events")
    func skipsStatus() {
        skipped(mapper.mapping(for: ["kind": ["type": "status"]]), reason: "status")
    }

    @Test("Skips unrecognized or malformed event shapes")
    func skipsUnsupportedEvents() {
        skipped(mapper.mapping(for: ["kind": ["type": "future_event"]]), reason: "unsupported")
        skipped(mapper.mapping(for: [:]), reason: "unsupported")
    }

    @Test("A file edit with no recorded path gets no location")
    func fileEditWithoutPathHasNoLocation() throws {
        let mapper = ACPSessionUpdateMapper(sessionID: "session-1", cwd: "/tmp/session")
        let value = try update(mapper.mapping(for: [
            "kind": ["type": "file_edit", "operation": "edit"],
        ]))
        #expect(value["title"] as? String == "edit (file)")
        #expect(value.keys.contains("locations") == false)
    }

    @Test("Drops paths that escape the session cwd or name an unknown home")
    func dropsPathsOutsideTheSessionRoot() throws {
        let mapper = ACPSessionUpdateMapper(sessionID: "session-1", cwd: "/tmp/session")
        let value = try update(mapper.mapping(for: [
            "kind": [
                "type": "tool_use",
                "referenced_paths": [
                    "../../../../etc/passwd",
                    "~/.ssh/id_rsa",
                    "nested/../kept.swift",
                ],
            ],
        ]))
        #expect((value["locations"] as? [[String: Any]])?.map { $0["path"] as? String }
            == ["/tmp/session/kept.swift"])
    }
}
