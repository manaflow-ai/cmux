import Foundation
import Testing
@testable import CmuxNextDaemon

/// Wire shapes of personal state (`profiles-v1`, plans/cmux-next/data-model.md 3.3).
@Suite struct PersonalStateTests {
    private func object<R: DaemonRequest>(_ request: R) throws -> [String: JSONValue] {
        let data = try WireCoding.encodeRequest(request, id: 1)
        guard case .object(let object) = try JSONDecoder().decode(JSONValue.self, from: data) else {
            throw DaemonError.malformedResponse("not an object")
        }
        return object
    }

    @Test func listPersonalDecodes() throws {
        let json = """
        {"personal_revision":7,
         "sessions":[{"session_id":"s1","machine_name":"mac","session_name":"cmux-app","transport":{"kind":"local"},
                      "last_seen_ms":1,"capabilities":["profiles-v1"],"migrated":true}],
         "profiles":[{"id":"default","name":"Default","color":null,"icon":null,"theme":null,"index":0,
                      "browser_profile_id":null,"default_session_id":null,"defaults":null,"follows":["s1"]},
                     {"id":"prof_a","name":"Work","color":"green","icon":"🚀","theme":"light:A,dark:B","index":1,
                      "browser_profile_id":"default","default_session_id":"s1","defaults":{"cwd":"/tmp","env":{"K":"V"}},"follows":[]}],
         "pins":[{"session_id":"s2","workspace_key":"k1","profile":"prof_a"}],
         "groups":[{"id":"grp_1","profile":"prof_a","name":"G","color":"red","collapsed":false,"index":0}],
         "workspaces":[{"session_id":"s1","workspace_key":"k2","index":0,"group":"grp_1","browser_profile_id":null,"theme":null}]}
        """
        let state = try WireCoding.decoder().decode(PersonalState.self, from: Data(json.utf8))
        #expect(state.revision == 7)
        #expect(state.sessions.first?.migrated == true)
        #expect(state.profiles[1].follows.isEmpty && state.profiles[0].follows == ["s1"])
        #expect(state.profiles[1].defaults?.env == ["K": "V"])
        #expect(state.profiles[1].browserProfileID == .defaultProfile)
        #expect(state.pins.first?.profile == "prof_a")
        #expect(state.groups.first?.profile == "prof_a")
        #expect(state.workspaces.first?.group == "grp_1")
    }

    @Test func requestsUseSnakeCaseAndNullClears() throws {
        let follows = try object(SetProfileFollowsRequest(profile: "prof_a", sessionIDs: ["s1"]))
        #expect(follows["session_ids"] == .array([.string("s1")]))
        let pin = try object(PinWorkspaceRequest(sessionID: "s2", workspaceKey: "k1", profile: "prof_a"))
        #expect(pin["session_id"] == .string("s2"))
        #expect(pin["workspace_key"] == .string("k1"))
        let clear = try object(SetPersonalWorkspaceRequest(sessionID: "s1", workspaceKey: "k2", group: .clear))
        #expect(clear["group"] == .null)
        #expect(clear["theme"] == nil)
        let update = try object(UpdateProfileRequest(profile: "prof_a", color: .clear, browserProfileID: .set("default")))
        #expect(update["color"] == .null)
        #expect(update["browser_profile_id"] == .string("default"))
        #expect(update["icon"] == nil)
    }

    @Test func windowRecordsWithoutARoomDecodeAsDefault() throws {
        let old = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"w","workspace_keys":["k"]}"#.utf8))
        #expect(old.profile == nil)
        #expect(old.profileWorkspaces.isEmpty)
        let new = try JSONDecoder().decode(WindowRecord.self, from: Data(
            #"{"id":"w","profile":"prof_a","profile_workspaces":{"prof_a":"k"}}"#.utf8))
        #expect(new.profile == "prof_a")
        #expect(new.profileWorkspaces["prof_a"] == "k")
    }
}
