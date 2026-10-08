import Foundation
import Testing
@testable import CmuxNextDaemon

/// Wire shapes of browser profile records (`browser-profiles-v1`,
/// plans/cmux-next/data-model.md section 5).
@Suite struct BrowserProfileWireTests {
    private func object<R: DaemonRequest>(_ request: R) throws -> [String: JSONValue] {
        let data = try WireCoding.encodeRequest(request, id: 1)
        guard case .object(let object) = try JSONDecoder().decode(JSONValue.self, from: data) else {
            throw DaemonError.malformedResponse("not an object")
        }
        return object
    }

    @Test func listPersonalDecodesBrowserProfiles() throws {
        let json = """
        {"personal_revision":3,"sessions":[],"profiles":[],"pins":[],"groups":[],"workspaces":[],
         "browser_profiles":[{"id":"default","name":"Default","color":null,"icon":null,"index":0,"source":null},
                             {"id":"3f2b1c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d","name":"Work","color":"green","icon":"💼","index":1,
                              "source":{"browser":"chrome","profile_dir":"Profile 1"}}]}
        """
        let state = try WireCoding.decoder().decode(PersonalState.self, from: Data(json.utf8))
        #expect(state.browserProfiles.map(\.id) == ["default", "3f2b1c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d"])
        #expect(state.browserProfiles[1].source == ["browser": "chrome", "profile_dir": "Profile 1"])
        #expect(state.browserProfiles[1].icon == "💼")
        // An older daemon has no browser_profiles key.
        let old = try WireCoding.decoder().decode(PersonalState.self, from: Data(#"{"personal_revision":1}"#.utf8))
        #expect(old.browserProfiles.isEmpty)
    }

    @Test func requestsUseSnakeCaseAndNullClears() throws {
        let create = try object(CreateBrowserProfileRequest(id: "3f2b1c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d", name: "Work", color: "green",
                                                            source: ["browser": "chrome"]))
        #expect(create["cmd"] == .string("create-browser-profile"))
        #expect(create["browser_profile"] == .string("3f2b1c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d"))
        #expect(create["source"] == .object(["browser": .string("chrome")]))
        #expect(create["icon"] == nil)
        let update = try object(UpdateBrowserProfileRequest(id: "default", color: .clear))
        #expect(update["cmd"] == .string("update-browser-profile"))
        #expect(update["color"] == .null)
        #expect(update["icon"] == nil && update["name"] == nil)
        let delete = try object(DeleteBrowserProfileRequest(id: "default"))
        #expect(delete["browser_profile"] == .string("default"))
        #expect(try object(MoveBrowserProfileRequest(id: "default", index: 2))["index"] == .number(2))
    }
}
