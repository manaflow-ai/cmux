import CmuxNextDevices
import Foundation
@testable import CmuxNextMacScreen
import Testing

/// A run's screen link (`acpmux share-host link`): `cmux://mac-screen?device=&display=[&control=1][&name=]`
/// and its web form `https://cmux.com/deeplink/screen?…` name one record, which round-trips through its
/// URL and its page tab route, and asks the host for that display in the cmux.rd/1 offer.
@MainActor
@Suite struct MacScreenRunLinkTests {
    static let device = "0f8e2c1a-3b4d-4e5f-8a9b-0c1d2e3f4a5b"

    @Test func aRunLinkParsesAndRoundTrips() throws {
        let url = try #require(URL(string: "cmux://mac-screen?device=\(Self.device.uppercased())&display=69734208&name=gui%20run"))
        let record = try #require(MacScreenRecord(url: url))
        #expect(record.deviceID == Self.device && record.display == 69_734_208 && !record.control && record.name == "gui run")
        #expect(record.isRunLink && record.scope == .view)
        #expect(MacScreenRecord(url: record.url) == record)
        #expect(record.url.absoluteString == "cmux://mac-screen?device=\(Self.device)&display=69734208&name=gui%20run")
        let control = try #require(MacScreenRecord(url: URL(string: "cmux://mac-screen?device=\(Self.device)&display=1&control=1")!))
        #expect(control.control && control.scope == .full && MacScreenRecord(url: control.url) == control)
    }

    @Test func aPlainDeviceRecordIsUnchanged() throws {
        let record = try #require(MacScreenRecord(url: URL(string: "cmux://mac-screen?device=\(Self.device)")!))
        #expect(record == MacScreenRecord(deviceID: Self.device) && !record.isRunLink && record.scope == .view)
        #expect(record.url.absoluteString == "cmux://mac-screen?device=\(Self.device)")
    }

    @Test func badDisplayIDsAndControlValuesAreDropped() throws {
        for bad in ["0", "-1", "abc", "4294967296", "1.5", "", "%D9%A1"] {
            let record = try #require(MacScreenRecord(url: URL(string: "cmux://mac-screen?device=\(Self.device)&display=\(bad)")!))
            #expect(record.display == nil && record.deviceID == Self.device, "display=\(bad)")
        }
        let record = try #require(MacScreenRecord(url: URL(string: "cmux://mac-screen?device=\(Self.device)&display=7&control=yes")!))
        #expect(!record.control)
        // No valid device: the home page, whatever else the link says.
        let home = try #require(MacScreenRecord(url: URL(string: "cmux://mac-screen?device=nope&display=7&control=1&name=x")!))
        #expect(home.isHome && home.display == nil && !home.control && home.name == nil)
    }

    @Test func theWebFormNamesTheSameRecord() throws {
        let native = try #require(MacScreenRecord(url: URL(string: "cmux://mac-screen?device=\(Self.device)&display=42")!))
        for web in ["https://cmux.com/deeplink/screen?device=\(Self.device)&display=42",
                    "https://www.cmux.com/deeplink/screen/?display=42&device=\(Self.device)",
                    "HTTPS://CMUX.COM/deeplink/screen?device=\(Self.device)&display=42"] {
            #expect(MacScreenRecord(link: try #require(URL(string: web))) == native, "\(web)")
        }
        #expect(try #require(MacScreenRecord(link: URL(string: "https://cmux.com/deeplink/screen")!)).isHome)
        for other in ["https://cmux.com/deeplink/agent?device=\(Self.device)", "http://cmux.com/deeplink/screen?device=\(Self.device)",
                      "https://evil.example/deeplink/screen?device=\(Self.device)", "https://cmux.com.evil.example/deeplink/screen"] {
            #expect(MacScreenRecord(link: try #require(URL(string: other))) == nil, "\(other)")
        }
        // The web form is a link, not an address a browser tab turns into a Mac Screen tab.
        #expect(MacScreenRecord(url: URL(string: "https://cmux.com/deeplink/screen?device=\(Self.device)")!) == nil)
    }

    @Test func thisBuildsLinkSchemeOpensTheSameRecord() throws {
        let link = try #require(URL(string: "cmux-dev://mac-screen?device=\(Self.device)&display=5"))
        #expect(MacScreenRecord(link: link, linkScheme: "cmux-dev")?.display == 5)
        #expect(MacScreenRecord(link: link, linkScheme: "cmux") == nil)
        #expect(MacScreenRecord(link: URL(string: "cmux-dev://agent?id=x")!, linkScheme: "cmux-dev") == nil)
    }

    @Test func theRouteKeepsTheRunsDisplay() throws {
        let record = MacScreenRecord(deviceID: Self.device, display: 9, control: true, name: "a&b+c=d #run")
        #expect(MacScreenRecord(url: record.url) == record)
        let route = MacScreenPages.route(of: record)
        #expect(route.hasPrefix("device:\(Self.device)?display=9&control=1&name="))
        #expect(MacScreenPages.record(route: route) == record)
        #expect(MacScreenPages.route(of: MacScreenRecord(deviceID: Self.device)) == "device:\(Self.device)")
        #expect(MacScreenPages.record(route: "device:\(Self.device)") == MacScreenRecord(deviceID: Self.device))
        #expect(MacScreenPages.record(route: "device:\(Self.device)?display=nope") == MacScreenRecord(deviceID: Self.device))
        #expect(MacScreenPages.record(route: "device:nope?display=9") == nil)
    }

    @Test func aRunsNameIsOneShortLine() {
        #expect(MacScreenRecord(deviceID: Self.device, name: "  two\nlines  ").name == "two lines")
        #expect(MacScreenRecord(deviceID: Self.device, name: "   ").name == nil)
        #expect(MacScreenRecord(deviceID: Self.device, name: String(repeating: "x", count: 200)).name?.count == 80)
    }

    @Test func theOfferNamesTheDisplayAndTheAnswerListsTheIDs() throws {
        var offer = MacScreenRdDocument(key: String(repeating: "ab", count: 32))
        offer.displayID = 69_734_208
        #expect(offer.text.contains("a=cmux-rd-display-id:69734208\r\n"))
        #expect(MacScreenRdDocument(text: offer.text)?.displayID == 69_734_208)
        var answer = MacScreenRdDocument(key: String(repeating: "cd", count: 32))
        answer.displays = [CGSize(width: 3024, height: 1964), CGSize(width: 1920, height: 1080)]
        answer.displayIDs = [1, 69_734_208]
        answer.currentDisplay = 1
        let parsed = try #require(MacScreenRdDocument(text: answer.text))
        #expect(parsed.displayIDs == [1, 69_734_208] && parsed.currentDisplay == 1)
        #expect(!parsed.lacksDisplay(69_734_208) && parsed.lacksDisplay(7))
        // An older host's answer lists no ids.
        answer.displayIDs = []
        #expect(try #require(MacScreenRdDocument(text: answer.text)).displayIDs.isEmpty)
        #expect(!answer.text.contains("display-ids"))
        // So an older host never says the run's display is gone: it shows its main display and no note.
        #expect(!(try #require(MacScreenRdDocument(text: answer.text))).lacksDisplay(69_734_208))
    }
}
