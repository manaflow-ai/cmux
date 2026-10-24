import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Foundation
import Testing

/// A close decides its question in the key's turn from the foreground programs the daemon pushed
/// (`terminal-foreground-v1`), and only from what it knows: before this connection's seed, or for
/// a terminal with no state yet, it asks the daemon (nil here), never closes a running program
/// without the question.
@MainActor @Suite(.serialized)
struct TabCloseGuardLocalTests {
    private static func services() throws -> (AppServices, TabModel) {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.daemon.store
        let json = #"{"app":"cmux-tui","protocol":1,"session":"close-guard-local","generation":"g1","capabilities":["terminal-foreground-v1"]}"#
        store.connectionState = .connected(try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8)))
        store.noteHandshake(try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8)))
        let pane = PaneSnapshot(id: PaneID(rawValue: 1), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 5), title: "vim")])
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: .leaf(pane.id), panes: [pane])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: nil, name: "w", screens: [screen])]))
        return (services, try #require(store.tab(surface: SurfaceID(rawValue: 5))))
    }

    @Test func aKnownRunningProgramAsksInTheKeysTurn() throws {
        let (services, tab) = try Self.services()
        let store = services.daemon.store
        try #require(services.daemon.supports(DaemonCapabilities.terminalForeground))
        store.foregrounds.seed([TerminalForeground(surface: tab.surface, seq: 1, foregroundPID: 40, foregroundExecutable: "/usr/bin/vim")],
                               epoch: store.connectionEpoch)
        let decided = try #require(TabCloseGuard.localPromptAndAnswers(closing: [tab], on: services.daemon, services: services))
        #expect(decided.prompt != nil, "a running vim closed with no question")
        #expect(decided.asked[tab.surface] == .some("vim"))
    }

    @Test func aKnownIdleShellClosesInTheKeysTurn() throws {
        let (services, tab) = try Self.services()
        let store = services.daemon.store
        store.foregrounds.seed([TerminalForeground(surface: tab.surface, seq: 1, foregroundPID: 40, foregroundExecutable: "-zsh")],
                               epoch: store.connectionEpoch)
        let decided = try #require(TabCloseGuard.localPromptAndAnswers(closing: [tab], on: services.daemon, services: services))
        #expect(decided.prompt == nil)
    }

    /// Review (2026-10-24): before the seed, or with no entry for the closing terminal, the close
    /// must ask the daemon, not treat unknown as idle.
    @Test func unknownStateFallsBackToTheDaemonRead() throws {
        let (services, tab) = try Self.services()
        let store = services.daemon.store
        #expect(TabCloseGuard.localPromptAndAnswers(closing: [tab], on: services.daemon, services: services) == nil, "no seed yet")
        store.foregrounds.seed([], epoch: store.connectionEpoch)
        #expect(TabCloseGuard.localPromptAndAnswers(closing: [tab], on: services.daemon, services: services) == nil, "no entry")
        _ = store.apply(.terminalForegroundChanged(TerminalForeground(surface: tab.surface, seq: 1, foregroundExecutable: "make")))
        #expect(TabCloseGuard.localPromptAndAnswers(closing: [tab], on: services.daemon, services: services)?.prompt != nil)
    }
}
