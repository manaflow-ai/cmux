@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextHistory
import CmuxNextHome
@testable import CmuxNextHomeEngine
import CmuxNextIPC
import Foundation
import Testing

/// History, Home's Chief owner calls and the page relay's confirmation send generated
/// `cmux.protocol/2` requests instead of runtime-named `ResourceRelayClient` envelopes, and every
/// migrated call writes the same line byte for byte. Each expected envelope below is the params
/// dictionary the call site built before the migration.
struct DaemonHistoryWireGoldenTests {
    private static let key = "cmux-next-history-k1"
    private static let at = Date(timeIntervalSince1970: 1_700_000_000.123)
    private static let dayStart = Date(timeIntervalSince1970: 1_699_920_000)

    private static func text(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }

    private static func handBuilt(_ operation: String, _ params: [String: JSONValue], keyed: Bool = true) throws -> String {
        text(try ResourceRequestEnvelope(id: 21, operation: operation, params: params,
                                         idempotencyKey: keyed ? key : nil).line())
    }

    private static func generated<Request: ResourceMutationRequest>(_ request: Request) throws -> String {
        text(try ResourceRequestLine(id: 21, request: request, idempotencyKey: ResourceIdempotencyKey(key)).line())
    }

    private static func generated<Request: ResourceUnkeyedRequest>(_ request: Request) throws -> String {
        text(try ResourceRequestLine(id: 21, request: request).line())
    }

    @Test func entriesListWithAndWithoutTextAndLimit() throws {
        let full = DaemonHistoryClient.listRequest(kinds: [.page, .agent, .location], text: "cmux docs", range: .week,
                                                   limit: 9_000, dayStart: Self.dayStart)
        #expect(try Self.generated(full) == Self.handBuilt("history.entries.list", [
            "kinds": .array([.string("agent"), .string("location"), .string("page")]), "range": .string("week"),
            "local_day_start_ms": .string("1699920000000"), "text": .string("cmux docs"), "limit": .number(5_000),
        ], keyed: false))
        let bare = DaemonHistoryClient.listRequest(kinds: [], text: "", range: .all, limit: nil, dayStart: Self.dayStart)
        #expect(try Self.generated(bare) == Self.handBuilt("history.entries.list", [
            "kinds": .array([]), "range": .string("all"), "local_day_start_ms": .string("1699920000000"),
        ], keyed: false))
        let clamped = DaemonHistoryClient.listRequest(kinds: [.closed], text: "", range: .today, limit: 0,
                                                      dayStart: Self.dayStart)
        #expect(try Self.generated(clamped) == Self.handBuilt("history.entries.list", [
            "kinds": .array([.string("closed")]), "range": .string("today"),
            "local_day_start_ms": .string("1699920000000"), "limit": .number(1),
        ], keyed: false))
    }

    @Test func removalsAndClear() throws {
        #expect(try Self.generated(V2HistoryEntriesRemoveRequest(ids: ["page:p:1", "location:7"]))
            == Self.handBuilt("history.entries.remove", ["ids": .array([.string("page:p:1"), .string("location:7")])]))
        #expect(try Self.generated(V2HistorySiteRemoveRequest(host: "example.com", profile: "default"))
            == Self.handBuilt("history.site.remove", ["host": .string("example.com"), "profile": .string("default")]))
        #expect(try Self.generated(V2HistorySiteRemoveRequest(host: "example.com", profile: nil))
            == Self.handBuilt("history.site.remove", ["host": .string("example.com")]))
        #expect(try Self.generated(V2HistoryVisitRemoveRequest(profile: "default", urls: ["https://a.test/x?y=1"]))
            == Self.handBuilt("history.visit.remove", ["profile": .string("default"),
                                                      "urls": .array([.string("https://a.test/x?y=1")])]))
        let clear = DaemonHistoryClient.clearRequest(kinds: [.page, .command], range: .hour, profile: "work",
                                                     dayStart: Self.dayStart)
        #expect(try Self.generated(clear) == Self.handBuilt("history.clear", [
            "kinds": .array([.string("command"), .string("page")]), "range": .string("hour"),
            "local_day_start_ms": .string("1699920000000"), "profile": .string("work"),
        ]))
        let clearAll = DaemonHistoryClient.clearRequest(kinds: [], range: .all, profile: nil, dayStart: Self.dayStart)
        #expect(try Self.generated(clearAll) == Self.handBuilt("history.clear", [
            "kinds": .array([]), "range": .string("all"), "local_day_start_ms": .string("1699920000000"),
        ]))
    }

    @Test func visitsTitlesImportAndSummaries() throws {
        let visit = DaemonHistoryClient.visitRequest(profile: "default", url: "https://a.test/", title: "A \"page\"",
                                                     tab: "mac/tab_1", at: Self.at)
        #expect(try Self.generated(visit) == Self.handBuilt("history.visit.record", [
            "profile": .string("default"), "url": .string("https://a.test/"), "at_ms": .string("1700000000123"),
            "tab": .string("mac/tab_1"), "title": .string("A \"page\""),
        ]))
        // An empty title and an unknown tab are left out.
        let untitled = DaemonHistoryClient.visitRequest(profile: "default", url: "https://a.test/", title: "", tab: nil,
                                                        at: Self.at)
        #expect(try Self.generated(untitled) == Self.handBuilt("history.visit.record", [
            "profile": .string("default"), "url": .string("https://a.test/"), "at_ms": .string("1700000000123"),
        ]))
        #expect(try Self.generated(V2HistoryVisitTitleRequest(profile: "default", title: "Docs", url: "https://a.test/"))
            == Self.handBuilt("history.visit.title", ["profile": .string("default"), "url": .string("https://a.test/"),
                                                     "title": .string("Docs")]))
        #expect(try Self.generated(V2HistoryVisitImportRequest(path: "/Users/me/History.sqlite", profile: "default"))
            == Self.handBuilt("history.visit.import", ["profile": .string("default"),
                                                      "path": .string("/Users/me/History.sqlite")]))
        #expect(try Self.generated(DaemonHistoryClient.summariesRequest(profile: "default", limit: 5_000))
            == Self.handBuilt("history.visit.summaries", ["profile": .string("default"), "limit": .number(5_000)],
                              keyed: false))
    }

    @Test func trailRecordCarriesTheWholePlace() throws {
        let location = HistoryLocation(key: .init(machine: "mac_1", tab: "tab_1"), window: "win_1", workspace: "ws_1",
                                       pane: "pane_1", screen: "scr_1", content: .terminal, title: "~/src",
                                       workspaceTitle: "Build", url: nil, cwd: "/Users/me/src")
        let place = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(HistoryTrailLocation(location)))
        let request = DaemonHistoryClient.trailRequest(window: "win_1", location: location, at: Self.at, steps: .everything,
                                                       jump: true)
        #expect(try Self.generated(request) == Self.handBuilt("history.trail.record", [
            "window": .string("win_1"), "location": place, "at_ms": .string("1700000000123"),
            "steps": .string("everything"), "jump": .bool(true),
        ]))
        let page = HistoryLocation(key: .init(machine: "top-page", tab: "cmux://history"), window: "win_1", workspace: "",
                                   pane: "", content: .other, title: "History", page: "cmux://history")
        let pagePlace = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(HistoryTrailLocation(page)))
        let step = DaemonHistoryClient.trailRequest(window: "win_1", location: page, at: Self.at, steps: .workspaces,
                                                    jump: false)
        #expect(try Self.generated(step) == Self.handBuilt("history.trail.record", [
            "window": .string("win_1"), "location": pagePlace, "at_ms": .string("1700000000123"),
            "steps": .string("workspaces"),
        ]))
    }

    @Test func chiefOwnerCallsAndConfirmation() throws {
        let current: [String: JSONValue] = ["machine": .string("current"), "session": .string("current")]
        #expect(try Self.generated(V2ChiefProfileListRequest()) == Self.handBuilt("chief.profile.list", current, keyed: false))
        var delete = current
        delete["chief"] = .string("agent_01HZX")
        #expect(try Self.generated(V2ChiefProfileDeleteRequest(chief: "agent_01HZX"))
            == Self.handBuilt("chief.profile.delete", delete))
        let digest = String(repeating: "ab", count: 32)
        #expect(try Self.generated(V2OriginConfirmationIssueRequest(operation: "chief.profile.create", paramsSha256: digest,
                                                                    relayConnectionID: "42"))
            == Self.handBuilt("origin.confirmation.issue", [
                "operation": .string("chief.profile.create"), "params_sha256": .string(digest),
                "relay_connection_id": .string("42"),
            ], keyed: false))
    }

    /// DaemonChiefAvatarRegistry's three calls (it added `machine` and `session` itself) and
    /// HomeLocalChiefCreator's create (its params named no selector).
    @Test func chiefAvatarAndCreateCalls() throws {
        let current: [String: JSONValue] = ["machine": .string("current"), "session": .string("current")]
        var get = current
        get["chief"] = .string("agent_01HZX")
        #expect(try Self.generated(V2ChiefProfileAvatarGetRequest(chief: "agent_01HZX"))
            == Self.handBuilt("chief.profile.avatar.get", get, keyed: false))
        // Bytes whose base64 has `/` (`iVBOR//77w==`), which the line must not escape.
        let picture = ChiefAvatarPicture(mediaType: "image/png", data: Data([0x89, 0x50, 0x4E, 0x47, 0xFF, 0xFB, 0xEF]))
        var set = current
        set["chief"] = .string("agent_01HZX")
        set["media_type"] = .string("image/png")
        set["data"] = .string(picture.data.base64EncodedString())
        #expect(try Self.generated(DaemonChiefAvatarRegistry.setRequest(picture, of: "agent_01HZX"))
            == Self.handBuilt("chief.profile.avatar.set", set))
        var clear = current
        clear["chief"] = .string("agent_01HZX")
        clear["clear"] = .bool(true)
        #expect(try Self.generated(DaemonChiefAvatarRegistry.clearRequest(of: "agent_01HZX"))
            == Self.handBuilt("chief.profile.avatar.set", clear))
        #expect(try Self.generated(HomeLocalChiefCreator.request(name: "Scout", backend: .unii))
            == Self.handBuilt("chief.profile.create", ["display_name": .string("Scout"), "harness": .string("unii")]))
        #expect(try Self.generated(HomeLocalChiefCreator.request(name: "Scout", backend: .claude))
            == Self.handBuilt("chief.profile.create", ["display_name": .string("Scout")]))
    }

    /// The replies the migrated calls read decode as the daemon writes them (history_ops,
    /// origin_gate.rs): a mutation's `value`, the trail step and the confirmation token.
    @Test func repliesDecode() throws {
        func result<T: Decodable>(_ type: T.Type, _ line: String) throws -> T {
            try ResourceRequestEnvelope.decodeResult(T.self, from: Data(line.utf8))
        }
        let imported = try result(ResourceMutationResult<V2HistoryVisitImportResult>.self,
                                  #"{"id":"1","ok":true,"result":{"value":{"imported":12},"generation":"g","revision":"3","replayed":false}}"#)
        #expect(imported.value.imported == 12)
        let step = try result(ResourceMutationResult<V2HistoryTrailRecordResult>.self,
                              #"{"id":"1","ok":true,"result":{"value":{"recorded":false},"generation":"g","revision":"3","replayed":false}}"#)
        #expect(step.value.id == nil)
        #expect(step.value.recorded == false)
        let token = try result(V2OriginConfirmation.self,
                               #"{"id":"1","ok":true,"result":{"token":"t","expires_at":"1700000060000"}}"#)
        #expect(token.token == "t")
    }

    /// The Chief registry's replies as the owner writes them (chief_registry_resource.rs): the list
    /// with one pictured and one bare record, and the picture page with and without a picture.
    @Test func chiefRegistryRepliesDecode() throws {
        func result<T: Decodable>(_ type: T.Type, _ line: String) throws -> T {
            try ResourceRequestEnvelope.decodeResult(T.self, from: Data(line.utf8))
        }
        let sha = String(repeating: "a", count: 64)
        let record = #""role":"","personality":"","instructions":"","tools":["spawn"],"harnesses":[],"engine":{},"#
            + #""self_edit":["avatar"],"locked":false,"rev":2,"created_at":"2026-10-26T00:00:00.000Z","#
            + #""updated_at":"2026-10-26T00:00:00.000Z""#
        let list = try result(V2ChiefProfileListRequest.Result.self, #"{"id":"1","ok":true,"result":{"chiefs":["#
            + #"{"id":"agent_mux","display_name":"Chief","is_default":true,"avatar":{"sha256":""# + sha
            + #"","media_type":"image/png","bytes":7},"# + record + "},"
            + #"{"id":"agent_scout01","display_name":"Scout","is_default":false,"avatar":null,"# + record
            + #"}],"deleted":["agent_gone01"]}}"#)
        #expect(list.chiefs.map(\.id) == ["agent_mux", "agent_scout01"])
        #expect(list.chiefs.map(\.avatar?.sha256) == [sha, nil])
        let page = try result(V2ChiefProfileAvatarGetRequest.Result.self, #"{"id":"1","ok":true,"result":{"#
            + #""chief":"agent_mux","avatar":{"sha256":""# + sha + #"","media_type":"image/png","bytes":7,"#
            + #""data":"iVBOR//77w=="}}}"#)
        #expect(page.avatar?.mediaType.rawValue == "image/png")
        #expect(page.avatar.flatMap { Data(base64Encoded: $0.data) }
            == Data([0x89, 0x50, 0x4E, 0x47, 0xFF, 0xFB, 0xEF]))
        let bare = try result(V2ChiefProfileAvatarGetRequest.Result.self,
                              #"{"id":"1","ok":true,"result":{"chief":"agent_scout01","avatar":null}}"#)
        #expect(bare.avatar == nil)
    }
}
