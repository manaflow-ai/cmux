import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct MobileTailscaleSuggestionTests {
    @Test func disconnectedSuggestionsLoadWithoutAComputerListRefresh() async throws {
        try await withStore { store, routes in
            let shell = makeShell(store)
            let suggestions = await shell.tailscaleRouteSuggestions(macDeviceID: "mac-a", instanceTag: "tsl3")
            #expect(Set(suggestions.map(\.endpoint)) == Set(routes.map(\.endpoint)))
            #expect(MobileComputerRouteGroup.groups(suggestions).count == 1)
            let saved = try #require(try await store.loadAll(stackUserID: "user-1").first)
            #expect(saved.legacyTailscaleRoutes == nil)
        }
    }

    @Test func acceptingOfflineGroupPersistsBothFamiliesAndRemovesSuggestion() async throws {
        try await withStore { store, _ in
            let shell = makeShell(store)
            let suggestions = await shell.tailscaleRouteSuggestions(macDeviceID: "mac-a", instanceTag: "tsl3")
            #expect(await shell.acceptTailscaleRouteSuggestions(suggestions, macDeviceID: "mac-a", instanceTag: "tsl3"))
            #expect(await shell.tailscaleRouteSuggestions(macDeviceID: "mac-a", instanceTag: "tsl3").isEmpty)
            let saved = try #require(try await store.loadAll(stackUserID: "user-1").first)
            #expect(saved.legacyTailscaleRoutes?.count == 2)
        }
    }

    @Test func suggestionsNeverCrossAccountOrInstance() async throws {
        try await withStore { store, routes in
            let shell = makeShell(store)
            #expect(await shell.tailscaleRouteSuggestions(macDeviceID: "mac-a", instanceTag: "other").isEmpty)
            let otherAccount = makeShell(store, userID: "user-2")
            #expect(await otherAccount.tailscaleRouteSuggestions(macDeviceID: "mac-a", instanceTag: "tsl3").isEmpty)
            #expect(await otherAccount.acceptTailscaleRouteSuggestions(routes, macDeviceID: "mac-a", instanceTag: "tsl3") == false)
        }
    }

    @Test func callerCannotAddAnUnannouncedRoute() async throws {
        try await withStore { store, _ in
            let shell = makeShell(store)
            let fabricated = try CmxAttachRoute(id: "unknown", kind: .tailscale,
                endpoint: .hostPort(host: "100.64.0.99", port: 64000))
            #expect(await shell.acceptTailscaleRouteSuggestions([fabricated], macDeviceID: "mac-a", instanceTag: "tsl3") == false)
        }
    }

    private func makeShell(_ store: MobilePairedMacStore, userID: String = "user-1") -> MobileShellComposite {
        MobileShellComposite(isSignedIn: true, connectionState: .disconnected,
            pairedMacStore: store, identityProvider: StaticIdentityProvider(userID: userID))
    }

    private func withStore(_ body: (MobilePairedMacStore, [CmxAttachRoute]) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try MobilePairedMacStore(databaseURL: directory.appendingPathComponent("paired.sqlite3"))
        let routes = try ["100.64.0.1", "fd7a:115c:a1e0::1"].map {
            try CmxAttachRoute(id: $0, kind: .tailscale, endpoint: .hostPort(host: $0, port: 64000), groupID: "peer-a")
        }
        try await store.upsert(macDeviceID: "mac-a", displayName: "Mac A", routes: routes,
            instanceTag: "tsl3", markActive: false, stackUserID: "user-1", now: Date())
        try await body(store, routes)
    }
}
