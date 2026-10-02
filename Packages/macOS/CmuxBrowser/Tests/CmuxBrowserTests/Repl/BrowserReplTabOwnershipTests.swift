import Testing
@testable import CmuxBrowser

@Suite struct BrowserReplTabOwnershipTests {
    @Test func aTabNoSessionCreatedKeepsTheUsersUI() {
        var ownership = BrowserReplTabOwnership()
        ownership.attach(sessionID: "agent")
        #expect(!ownership.isSessionOwned)
        for event in BrowserReplTabEvent.allCases {
            #expect(!ownership.routesToSessions(event))
        }
    }

    @Test func aTabTheSessionCreatedRoutesEverythingToIt() {
        var ownership = BrowserReplTabOwnership()
        ownership.markCreated(by: "agent")
        #expect(ownership.isSessionOwned)
        for event in BrowserReplTabEvent.allCases {
            #expect(ownership.routesToSessions(event))
        }
    }

    @Test func aHandlerOnAUsersTabTakesOnlyItsEvent() {
        var ownership = BrowserReplTabOwnership()
        ownership.attach(sessionID: "agent")
        ownership.setHandledEvents([.dialog], for: "agent")
        #expect(ownership.routesToSessions(.dialog))
        #expect(!ownership.routesToSessions(.fileChooser))
        #expect(!ownership.routesToSessions(.download))
        #expect(!ownership.isSessionOwned)
        ownership.setHandledEvents([], for: "agent")
        #expect(!ownership.routesToSessions(.dialog))
    }

    @Test func handlersEndWithTheirSession() {
        var ownership = BrowserReplTabOwnership()
        ownership.attach(sessionID: "a")
        ownership.attach(sessionID: "b")
        ownership.setHandledEvents([.download], for: "a")
        ownership.detach(sessionID: "a")
        #expect(!ownership.routesToSessions(.download))
        // A session that is not attached cannot register handlers.
        ownership.setHandledEvents([.download], for: "a")
        #expect(!ownership.routesToSessions(.download))
    }

    @Test func theTabIsTheUsersOnceItsCreatorLeaves() {
        var ownership = BrowserReplTabOwnership()
        ownership.markCreated(by: "creator")
        ownership.attach(sessionID: "other")
        ownership.detach(sessionID: "creator")
        #expect(!ownership.isSessionOwned)
        #expect(!ownership.routesToSessions(.dialog))
        #expect(ownership.creatorSessionID == nil)
    }

    @Test func eventNamesParseStrictly() {
        #expect(BrowserReplTabOwnership.events(named: ["dialog", "filechooser", "download"]) == Set(BrowserReplTabEvent.allCases))
        #expect(BrowserReplTabOwnership.events(named: []) == [])
        #expect(BrowserReplTabOwnership.events(named: ["dialog", "popup"]) == nil)
    }
}
