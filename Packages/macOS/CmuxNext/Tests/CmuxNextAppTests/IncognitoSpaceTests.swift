import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Foundation
import Testing

/// Incognito spaces (Lawrence 14223, plans/cmux-next/spaces-overhaul-DESIGN.md rule 2): New Incognito
/// Space opens a new space in a new incognito window; nothing of it is kept: the space is deleted once its
/// window is gone (and at quit, and at the next launch after a crash, through the incognito ledger).
@MainActor @Suite(.serialized)
struct IncognitoSpaceTests {
    static func services() -> AppServices {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.windows.ordersWindowsIn = false
        return services
    }

    @Test func anIncognitoSpacesWindowIsIncognitoAndShowsTheSpace() {
        let services = Self.services()
        let space = ProfileID(rawValue: "prof_incognito")
        let window = services.windows.newIncognitoWindow(space: space)
        #expect(services.windows.isIncognito(window: window))
        #expect(services.windows.state(for: window).profileID == space)
        #expect(services.windows.incognitoSpaces[window] == space)
    }

    /// The window never opened (or closed): the space ends with it; a window still waiting keeps its space.
    @Test func theSpaceEndsWithItsWindow() {
        let services = Self.services()
        let space = ProfileID(rawValue: "prof_incognito")
        let window = services.windows.newIncognitoWindow(space: space)
        services.windows.endIncognitoSpacesIfUnused()
        #expect(services.windows.incognitoSpaces[window] == space, "a window still being created lost its space")
        services.windows.pendingClaims = services.windows.pendingClaims.filter { $0.value != window }
        services.windows.pendingEphemeralWindows.removeAll { $0 == window }
        services.windows.endIncognitoSpacesIfUnused()
        #expect(services.windows.incognitoSpaces[window] == nil)
    }

    /// The ledger keeps the incognito spaces, so a crashed run's are deleted at the next launch.
    @Test func theLedgerKeepsTheIncognitoSpaces() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "incognito-space-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledger = IncognitoWorkspaceLedger(url: directory.appending(path: "incognito-workspaces.json"))
        await ledger.record([], spaces: ["prof_a"])?.value
        #expect(ledger.hasLeftovers)
        #expect(await ledger.loadSpaces() == ["prof_a"])
        #expect(await ledger.load().isEmpty)
        // The space deleted: the file goes.
        await ledger.record([], spaces: [])?.value
        #expect(!ledger.hasLeftovers)
    }
}
