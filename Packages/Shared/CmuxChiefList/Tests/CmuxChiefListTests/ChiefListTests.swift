import CmuxChiefList
import Foundation
import Testing

/// The one Chief list rule every Home calls (the Mac's `HomeChiefRoster`, the iPhone's `HomeChiefs`).
@Suite struct ChiefListTests {
    struct Cloud: ChiefListCloudChief {
        var mainConversation: String?
        var isDefault: Bool
        var isPlaced: Bool
    }

    static let mac = ChiefList.Chief(conversation: "mac", isCloud: false)
    static let named = ChiefList.Chief(conversation: "mac-named", isCloud: false)
    static let hosted = ChiefList.Chief(conversation: "hosted", isCloud: true)
    static let other = ChiefList.Chief(conversation: "other", isCloud: true)
    static let placed = ChiefList.Chief(conversation: "placed", isCloud: true)

    static func make(_ chiefs: [ChiefList.Chief], local: String? = "mac", hosted: String? = "hosted", placed: String? = nil,
                     server: String? = nil, showsPlaced: Bool = false, prefersLocal: Bool = false) -> ChiefList {
        ChiefList(chiefs: chiefs, local: local, hosted: hosted, placed: placed, server: server,
                  showsPlaced: showsPlaced, prefersLocal: prefersLocal)
    }

    static func tag(_ list: ChiefList, _ id: String, engine: String? = nil) -> String? {
        list.tag(for: id, engine: engine, mainLabel: "Main") { place in
            switch place {
            case .thisMac: "This Mac"
            case .cloud: "Cloud"
            case let .server(name): name.isEmpty ? "Paired server" : name
            }
        }
    }

    @Test func listsEveryChiefOnEveryHostOnce() {
        let list = Self.make([Self.mac, Self.named, Self.hosted, Self.other, Self.hosted])
        #expect(list.conversations == ["mac", "mac-named", "hosted", "other"])
        #expect(list.places == ["mac": .thisMac, "mac-named": .thisMac, "hosted": .cloud, "other": .cloud])
    }

    @Test func mainIsTheCloudChiefUnlessTheMacsChiefIsTheDefault() {
        #expect(Self.make([Self.mac, Self.hosted]).main == "hosted")
        #expect(Self.make([Self.mac, Self.hosted], prefersLocal: true).main == "mac")
        // The Mac's Chief counts only when listed.
        #expect(Self.make([Self.hosted], prefersLocal: true).main == "hosted")
        // No cloud Chief: the Mac's.
        #expect(Self.make([Self.mac], hosted: nil).main == "mac")
        // Nothing known.
        #expect(Self.make([], local: nil, hosted: nil).main == nil)
    }

    @Test func thePlacedChiefIsMainWhenPicked() {
        let chiefs = [Self.mac, Self.hosted, Self.placed]
        #expect(Self.make(chiefs, placed: "placed", server: "cmux20").main == "hosted")
        let picked = Self.make(chiefs, placed: "placed", server: "cmux20", showsPlaced: true)
        #expect(picked.main == "placed")
        #expect(picked.places["placed"] == .server("cmux20"))
        #expect(Self.tag(picked, "placed") == "Main \u{00B7} cmux20")
        // No server name yet.
        #expect(Self.tag(Self.make(chiefs, placed: "placed"), "placed") == "Paired server")
    }

    @Test func tagsSayMainThenPlaceThenEngine() {
        let list = Self.make([Self.mac, Self.named, Self.hosted, Self.other])
        #expect(Self.tag(list, "hosted") == "Main \u{00B7} Cloud")
        #expect(Self.tag(list, "other") == "Cloud")
        #expect(Self.tag(list, "mac") == "This Mac")
        #expect(Self.tag(list, "mac-named", engine: "UniiChat") == "This Mac \u{00B7} UniiChat")
        #expect(Self.tag(list, "unknown") == nil)
    }

    @Test func mainFirstLeadsWithTheMainChief() {
        #expect(Self.make([Self.mac, Self.named, Self.hosted]).mainFirst == ["hosted", "mac", "mac-named"])
        #expect(Self.make([Self.mac, Self.named, Self.hosted], prefersLocal: true).mainFirst == ["mac", "mac-named", "hosted"])
    }

    @Test func launchKeepsTheLastLaunchsMainAndPlaces() {
        let last = ChiefList(main: "hosted", places: ["hosted": .cloud, "mac": .thisMac])
        let now = Self.make([Self.mac, Self.hosted], hosted: nil)  // cloud not read: every row "This Mac", Main the Mac's
        let launching = now.launching(last: last)
        #expect(launching.main == "hosted")
        #expect(launching.places["hosted"] == .cloud)
        #expect(now.launching(last: last, keepsMain: true).main == "mac")
    }

    @Test func hostedAndPlacedPickTheDefaultFirst() {
        let chiefs = [Cloud(mainConversation: "a", isDefault: false, isPlaced: false),
                      Cloud(mainConversation: "b", isDefault: true, isPlaced: false),
                      Cloud(mainConversation: nil, isDefault: true, isPlaced: false),
                      Cloud(mainConversation: "p1", isDefault: false, isPlaced: true),
                      Cloud(mainConversation: "p2", isDefault: true, isPlaced: true)]
        #expect(ChiefList.hosted(in: chiefs)?.mainConversation == "b")
        #expect(ChiefList.placed(in: chiefs)?.mainConversation == "p2")
        #expect(ChiefList.cloudChiefs(chiefs).map(\.conversation) == ["a", "b", "p1", "p2"])
        #expect(ChiefList.hosted(in: [Cloud(mainConversation: "x", isDefault: false, isPlaced: true)]) == nil)
    }

    @Test func defaultFollowsTheEngineRow() {
        #expect(ChiefDefault(setting: nil) == .auto)
        #expect(ChiefDefault(setting: "bogus") == .auto)
        #expect(ChiefDefault.auto.prefersLocal(localRunning: true))
        #expect(!ChiefDefault.auto.prefersLocal(localRunning: false))
        #expect(ChiefDefault.local.prefersLocal(localRunning: false))
        #expect(!ChiefDefault.hosted.prefersLocal(localRunning: true))
    }

    @Test func placesEncodeAsBefore() throws {
        // The same case names and coding as the Mac's HomeChiefPlace, which its launch cache keeps.
        let data = try JSONEncoder().encode([ChiefPlace.thisMac, .cloud, .server("cmux20")])
        let text = String(decoding: data, as: UTF8.self)
        #expect(text == #"[{"thisMac":{}},{"cloud":{}},{"server":{"_0":"cmux20"}}]"#)
    }
}
