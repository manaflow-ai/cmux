import Testing

@testable import CmuxSidebar

@Suite struct RightSidebarModeTests {
    @Test func rawValuesAreStableWireFormat() {
        #expect(RightSidebarMode.files.rawValue == "files")
        #expect(RightSidebarMode.find.rawValue == "find")
        #expect(RightSidebarMode.sessions.rawValue == "sessions")
        #expect(RightSidebarMode.feed.rawValue == "feed")
        #expect(RightSidebarMode.dock.rawValue == "dock")
    }

    @Test func cliArgumentParsesCanonicalNames() {
        #expect(RightSidebarMode.from(cliArgument: "files") == .files)
        #expect(RightSidebarMode.from(cliArgument: "find") == .find)
        #expect(RightSidebarMode.from(cliArgument: "sessions") == .sessions)
        #expect(RightSidebarMode.from(cliArgument: "feed") == .feed)
        #expect(RightSidebarMode.from(cliArgument: "dock") == .dock)
    }

    @Test func cliArgumentAcceptsVaultAliasForSessions() {
        #expect(RightSidebarMode.from(cliArgument: "vault") == .sessions)
    }

    @Test func cliArgumentIsCaseAndWhitespaceInsensitive() {
        #expect(RightSidebarMode.from(cliArgument: "  FILES ") == .files)
        #expect(RightSidebarMode.from(cliArgument: "Vault") == .sessions)
    }

    @Test func cliArgumentRejectsUnknown() {
        #expect(RightSidebarMode.from(cliArgument: "nope") == nil)
        #expect(RightSidebarMode.from(cliArgument: "") == nil)
    }

    @Test func alwaysAvailableModesIgnoreGates() {
        for mode in [RightSidebarMode.files, .find, .sessions] {
            #expect(mode.isAvailable(feedEnabled: false, dockEnabled: false))
            #expect(mode.isAvailable(feedEnabled: true, dockEnabled: true))
        }
    }

    @Test func feedAndDockFollowTheirGates() {
        #expect(RightSidebarMode.feed.isAvailable(feedEnabled: true, dockEnabled: false))
        #expect(!RightSidebarMode.feed.isAvailable(feedEnabled: false, dockEnabled: true))
        #expect(RightSidebarMode.dock.isAvailable(feedEnabled: false, dockEnabled: true))
        #expect(!RightSidebarMode.dock.isAvailable(feedEnabled: true, dockEnabled: false))
    }

    @Test func availableModesFiltersGatedModesInDeclarationOrder() {
        #expect(
            RightSidebarMode.availableModes(feedEnabled: false, dockEnabled: false)
                == [.files, .find, .sessions]
        )
        #expect(
            RightSidebarMode.availableModes(feedEnabled: true, dockEnabled: true)
                == [.files, .find, .sessions, .feed, .dock]
        )
        #expect(
            RightSidebarMode.availableModes(feedEnabled: true, dockEnabled: false)
                == [.files, .find, .sessions, .feed]
        )
    }
}
