import CmuxNextDictation
import Foundation
import Testing

@Suite struct VoiceRoomAddressTests {
    @Test func emptyIsTheLocalServer() throws {
        let address = try #require(VoiceRoomAddress(setting: "  "))
        #expect(address.base.absoluteString == "http://127.0.0.1:4788/")
        #expect(address.transcript.absoluteString == "http://127.0.0.1:4788/api/transcript")
        #expect(address.events.absoluteString == "ws://127.0.0.1:4788/ws?observer=1")
    }

    @Test func aTailnetRoomUsesSecureSockets() throws {
        let address = try #require(VoiceRoomAddress(setting: "https://mac.tail1.ts.net:4789?x=1#top"))
        #expect(address.base.absoluteString == "https://mac.tail1.ts.net:4789/")
        #expect(address.events.absoluteString == "wss://mac.tail1.ts.net:4789/ws?observer=1")
    }

    @Test(arguments: ["file:///etc/passwd", "javascript:alert(1)", "not a url", "http://"])
    func onlyWebAddressesAreRooms(_ setting: String) {
        #expect(VoiceRoomAddress(setting: setting) == nil)
    }
}
