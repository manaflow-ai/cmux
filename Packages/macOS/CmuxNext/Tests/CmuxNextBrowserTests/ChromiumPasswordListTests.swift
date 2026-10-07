@testable import CmuxNextBrowser
import Foundation
import Testing

/// The fork's `cmux_password_list` JSON (API 18) as Passwords page rows: metadata only.
struct ChromiumPasswordListTests {
    @Test func readsSignInsAndNeverSaveSites() throws {
        let json = """
        {"passwords":[{"id":"7","site":"github.com","url":"https://github.com/login","username":"octo",
        "created":1759700000000,"last_used":0,"times_used":3,"weak":true,"reused":false},
        {"id":"9","site":"example.org","url":"https://example.org/","username":"",
        "created":0,"last_used":1759800000000,"times_used":0,"weak":false,"reused":true}],
        "exceptions":[{"id":"2","site":"bank.example"}]}
        """
        let list = try #require(ChromiumPasswordList.parse(json))
        #expect(list.passwords.map(\.id) == ["7", "9"])
        #expect(list.passwords[0].site == "github.com" && list.passwords[0].username == "octo")
        #expect(list.passwords[0].created == Date(timeIntervalSince1970: 1_759_700_000))
        #expect(list.passwords[0].lastUsed == nil, "0 means never")
        #expect(list.passwords[0].timesUsed == 3 && list.passwords[0].weak && !list.passwords[0].reused)
        #expect(list.passwords[1].created == nil && list.passwords[1].reused)
        #expect(list.exceptions == [ChromiumPasswordList.Exception(id: "2", site: "bank.example")])
    }

    @Test func refusesWhatIsNotTheListObject() {
        #expect(ChromiumPasswordList.parse("") == nil)
        #expect(ChromiumPasswordList.parse("[]") == nil)
        // Rows without an id are dropped; missing sections are empty.
        #expect(ChromiumPasswordList.parse(#"{"passwords":[{"site":"a"}]}"#) == ChromiumPasswordList(passwords: [], exceptions: []))
    }
}
