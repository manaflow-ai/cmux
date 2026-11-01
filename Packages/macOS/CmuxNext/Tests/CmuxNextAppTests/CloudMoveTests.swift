import AppKit
import CmuxNextActions
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextCloud
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextSettings
import CmuxNextWakeups
import Foundation
import Testing

/// Move to Cloud (cmuxterm-hq#1874 slice 3) at the app boundary: `cmux cloud move` on a live
/// chat tab, sent as the CLI sends it (`action.run`, `cli: true`, origin `cli`, a `tab:` target)
/// to the app's real action registry. This Mac is a real cmux-tui daemon; the Cloud machine is a
/// second real daemon reached the way the app reaches a machine's link socket
/// (`DaemonService.start(remote:)` on a ``CloudMachineSession``). `cmux link seed push` and
/// `cmux link agent move` are a stand-in `cmux` that records its arguments and answers their
/// JSON lines as the case asks; the Rust suites cover those CLIs against daemons (link_sync.rs,
/// link_agent_move.rs, cloud_move_journey.rs).
@MainActor @Suite(.serialized, .timeLimit(.minutes(2)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct CloudMoveTests {
    /// The live chat moves: its folder is synced under the machine's work root, the chat is moved
    /// from this Mac's tab to that folder, and the machine shows it in a Cloud workspace whose
    /// terminal runs in the synced folder. The chat's tab there is bound to the moved session
    /// through the machine's store (so it attaches through that machine and carries its badge),
    /// and this Mac's tab, whose chat closed, is gone.
    @Test func aCLIMoveOfALiveChatEndsWithTheTabAttachedToTheMachineChat() async throws {
        try await Self.withMove("moves") { move in
            if let error = await move.run() { Issue.record("cmux cloud move: \(error.code) \(error.message)") }
            let moved = try await move.read()

            let synced = move.workRoot.appendingPathComponent(moved.folderName).path
            #expect(moved.calls.first == ["link", "seed", "push", "--socket", move.vmSocket, move.project.path, synced])
            #expect(moved.calls.dropFirst().first == ["link", "agent", "move", "--from-socket", moved.macSocket, "--surface", String(moved.surface),
                                                     "--to-socket", move.vmSocket, "--cwd", synced, "--interrupt",
                                                     "--sync", "seed", "--sync-socket", move.vmSocket, "--sync-local", move.project.path,
                                                     "--sync-remote", synced, "--vm-kind", "none"],
                    "no link said this caller owns the machine: the pump says so, and the machine refuses")
            #expect(moved.calls.count == 2)
            // The machine shows the chat: bound to the moved session through that machine's store.
            let tab = try #require(moved.machineTab, "no chat tab on the machine")
            #expect(tab.agentSession?.session == "chat-on-vm")
            #expect(tab.agentSession?.host == "registry:" + moved.machineStore)
            #expect(tab.agentSession?.harness == "claude")
            #expect(moved.attachesThroughMachine, "the moved chat does not attach through the machine")
            #expect(moved.badge == "Move VM", "the moved chat's tab carries no Cloud badge")
            #expect(moved.terminalFolders == [synced], "the machine workspace's terminal is not in the synced folder")
            // This Mac's tab is gone (its chat closed with the move), with nothing left to retry.
            #expect(!moved.macStillHasTab)
            #expect(move.services.cloud.moveRetries[move.key] == nil)
        }
    }

    /// A CLI run whose daemon command reports an event sequence (here a rename of the chat tab) answers once a
    /// snapshot shows that sequence, never at its deadline. A move whose window-record save (a focus move) joined
    /// its run waited out the whole minute on aws-m4pro-8, where that save opened inside the run.
    @Test func aCLIRunThatSendsADaemonCommandAnswersOnceTheSnapshotShowsIt() async throws {
        try await Self.withMove("moves") { move in
            let started = ContinuousClock.now
            let error = await move.cli("tab rename", args: ["name": .string("Renamed Chat")])
            let took = ContinuousClock.now - started
            #expect(error == nil, "cmux tab rename: \(error.map { "\($0.code) \($0.message)" } ?? "")")
            #expect(took < .seconds(10), "the run answered after \(took), not once its rename showed")
        }
    }

    /// How a move stops: the stand-in `cmux link agent move` answer (or the machine tab's failure).
    enum Stop: String, CaseIterable, Sendable {
        case unresolved, inProgress, badAnswer, timeout, tabFailed, teamMachine
    }

    /// A move that stops keeps this Mac's tab and leaves the right Retry: one that may not have
    /// moved the chat runs the move again on the same machine; one whose chat moved but whose
    /// machine tab didn't open only opens that tab, without syncing or moving again; a team
    /// machine offers none.
    @Test(arguments: Stop.allCases)
    func aMoveThatStopsKeepsTheTabAndRetriesOnlyWhatIsLeft(_ stop: Stop) async throws {
        try await Self.withMove(stop.rawValue) { move in
            let error = await move.run()
            #expect(error != nil, "the move did not report that it stopped")
            #expect(move.services.locateTab(move.tabID, onMachine: move.services.machines.local.machineID) != nil, "this Mac's tab closed though its chat is not on the machine")
            let calls = move.calls()
            #expect(calls.count == 2, "\(calls)")
            let retry = move.services.cloud.moveRetries[move.key]
            switch stop {
            case .teamMachine:
                #expect(retry == nil, "a team machine is offered Retry")
            case .unresolved, .inProgress, .badAnswer, .timeout:
                #expect(retry == .move(machineID: "vm-move"), "Retry does not finish the move on its machine: \(String(describing: retry))")
            case .tabFailed:
                guard case .show(let shown) = retry else {
                    Issue.record("Retry does not only open the moved chat's tab: \(String(describing: retry))")
                    return
                }
                let synced = try #require(calls.first?.last)
                #expect(shown.session == "chat-on-vm" && shown.machineID == "vm-move" && shown.folder == synced && shown.key == "tr-1")
                // Retry, once the folder is there: only the tab opens.
                try FileManager.default.createDirectory(atPath: synced, withIntermediateDirectories: true)
                if let again = await move.run() { Issue.record("Retry failed: \(again.code) \(again.message)") }
                let moved = try await move.read()
                #expect(moved.calls.count == 2, "Retry synced or moved the chat again: \(moved.calls)")
                #expect(moved.machineTab?.agentSession?.session == "chat-on-vm", "Retry did not open the moved chat's tab")
                #expect(moved.terminalFolders == [synced])
                #expect(!moved.macStillHasTab)
                #expect(move.services.cloud.moveRetries[move.key] == nil)
            }
        }
    }

    /// A sync that throws instead of answering (the CLI timed out, or didn't launch) keeps this
    /// Mac's tab and the move retryable on the same machine; it never clears that Retry (cx-rppd.8).
    @Test func aSyncThatThrowsKeepsTheMoveRetryableOnItsMachine() async throws {
        try await Self.withMove("syncTimeout") { move in
            let error = await move.run()
            #expect(error != nil, "the move did not report that it stopped")
            #expect(move.services.locateTab(move.tabID, onMachine: move.services.machines.local.machineID) != nil, "this Mac's tab closed though nothing moved")
            #expect(move.calls().count == 1, "the chat moved after a failed sync: \(move.calls())")
            let retry = move.services.cloud.moveRetries[move.key]
            #expect(retry == .move(machineID: "vm-move"), "Retry does not run the move again on its machine: \(String(describing: retry))")
        }
    }

    /// A moved chat stays where the move put it across a quit and relaunch: the relaunched app shows
    /// its tab on the machine, still bound to the moved session through the machine's store (so it
    /// attaches through that machine), offers Bring Back Local for it, and has no Retry left.
    @Test func aMovedChatStaysAttachedToTheMachineChatAfterARelaunch() async throws {
        try await Self.withMove("moves") { move in
            if let error = await move.run() { Issue.record("cmux cloud move: \(error.code) \(error.message)") }
            _ = try await move.read()
            try await move.relaunch(tabClosed: true)
            let moved = try await move.read()
            let tab = try #require(moved.machineTab, "the relaunched app shows no chat tab on the machine")
            #expect(tab.agentSession?.session == "chat-on-vm")
            #expect(tab.agentSession?.host == "registry:" + moved.machineStore)
            #expect(moved.attachesThroughMachine, "after the relaunch the moved chat does not attach through the machine")
            let record = try #require(tab.agentSession)
            #expect(!CloudBringBack.hiddenMenuItems(record, movedChats: move.services.cloud.movedChats).contains(CloudBringBack.action),
                    "after the relaunch the machine tab has no Bring Back Local row")
            #expect(move.services.cloud.moveRetries[move.key] == nil)
        }
    }

    /// A quit or an update relaunch after a move committed but its machine tab didn't open keeps
    /// the move's Retry: the relaunched app (same daemons, same defaults) only opens the moved
    /// chat's tab on its machine, without syncing or moving the chat again.
    @Test func aCommittedMoveWhoseTabFailedStillOpensItAfterARelaunch() async throws {
        try await Self.withMove("tabFailed") { move in
            #expect(await move.run() != nil, "the move did not report that it stopped")
            let synced = try #require(move.calls().first?.last)
            try await move.relaunch()
            guard case .show(let shown)? = move.services.cloud.moveRetries[move.key] else {
                Issue.record("the relaunched app lost the move's Retry: \(String(describing: move.services.cloud.moveRetries[move.key]))")
                return
            }
            #expect(shown.session == "chat-on-vm" && shown.machineID == "vm-move" && shown.folder == synced)
            try FileManager.default.createDirectory(atPath: synced, withIntermediateDirectories: true)
            if let again = await move.run() { Issue.record("Retry after the relaunch failed: \(again.code) \(again.message)") }
            let moved = try await move.read()
            #expect(moved.calls.count == 2, "Retry after the relaunch synced or moved the chat again: \(moved.calls)")
            #expect(moved.machineTab?.agentSession?.session == "chat-on-vm", "Retry after the relaunch did not open the moved chat's tab")
            #expect(!moved.macStillHasTab)
            #expect(move.services.cloud.moveRetries[move.key] == nil)
        }
    }

    /// A move the app quits in the middle of (here, while its folder syncs) is pinned to its
    /// machine for the relaunched app: running it again finishes it there, never on another one.
    @Test func aMoveInterruptedByAQuitFinishesOnItsMachineAfterTheRelaunch() async throws {
        try await Self.withMove("syncTimeout") { move in
            move.services.cloud.move.timeout = .seconds(60)
            move.start()
            let deadline = ContinuousClock.now + .seconds(20)
            while move.calls().isEmpty, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
            #expect(move.calls().count == 1, "the move never started its sync: \(move.calls())")
            try await move.relaunch()
            let retry = move.services.cloud.moveRetries[move.key]
            #expect(retry == .move(machineID: "vm-move"), "the relaunched app does not finish the move on its machine: \(String(describing: retry))")
        }
    }

    /// A move a quit interrupted is never left half-done without a word: the relaunched app shows
    /// a card in the chat (the move didn't finish, Retry or dismiss), and its Retry runs the move
    /// again on the machine it was pinned to (cx-rppd.16).
    @Test func aMoveInterruptedByAQuitOffersRetryInItsChatAfterTheRelaunch() async throws {
        try await Self.withMove("syncTimeout") { move in
            try await Self.interruptByQuit(move)
            let card = try #require(await move.toolCards()?.first, "the relaunched app says nothing about the unfinished move")
            #expect(Self.text(card, "text") == CloudMoveStrings.unfinishedMove)
            #expect(Self.actionIDs(card) == ["retry", "dismiss"], "\(Self.actionIDs(card))")

            // The chat's folder, as this Mac's acpmux reports it for the chat's session (a person's
            // Retry names no path; the CLI run before the quit did).
            move.services.agentTabs.localSessionHost = SessionFolderHost(folder: move.project.path)
            _ = await move.answer(try #require(Self.text(card, "id")), "retry", gesture: true)
            let deadline = ContinuousClock.now + .seconds(20)
            while move.calls().count < 2, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
            let after = await move.toolCards(waiting: false)?.first.flatMap { Self.text($0, "text") }
            let again = try #require(move.calls().dropFirst().first, "Retry did not run the move again: \(move.calls()); card: \(after ?? "none")")
            #expect(Array(again.prefix(5)) == ["link", "seed", "push", "--socket", move.vmSocket], "Retry ran somewhere else: \(again)")
        }
    }

    /// A person who dismissed that card is not asked again at the next launch for the same move.
    @Test func aDismissedUnfinishedMoveStaysQuietAfterTheNextRelaunch() async throws {
        try await Self.withMove("syncTimeout") { move in
            try await Self.interruptByQuit(move)
            let card = try #require(await move.toolCards()?.first, "the relaunched app says nothing about the unfinished move")
            _ = await move.answer(try #require(Self.text(card, "id")), "dismiss", gesture: true)
            try await move.relaunch()
            // The offer runs once this Mac's tree is loaded (relaunch waited for the tab): give it a moment.
            try? await Task.sleep(for: .seconds(2))
            #expect(move.services.cloud.toolCards.cards(tab: move.key).isEmpty, "the dismissed move asks again")
            #expect(move.services.cloud.moveRetries[move.key] == .move(machineID: "vm-move"), "dismissing dropped the move's machine pin")
        }
    }

    /// Starts the move, lets its folder sync begin, then quits and relaunches the app.
    private static func interruptByQuit(_ move: Move) async throws {
        move.services.cloud.move.timeout = .seconds(60)
        move.start()
        let deadline = ContinuousClock.now + .seconds(20)
        while move.calls().isEmpty, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        try #require(move.calls().count == 1, "the move never started its sync: \(move.calls())")
        try await move.relaunch()
    }

    /// A machine whose cmux-tui is too old for the move (cx-rppd.13) is named as one in plain words,
    /// whether the folder copy or the chat move found it, and nothing moves: this Mac's tab stays and
    /// the toast offers "Update Machine" on that machine.
    @Test(arguments: ["syncOutdated", "outdated"])
    func anOutdatedMachineIsNamedAndTheChatStaysHere(_ mode: String) async throws {
        try await Self.withMove(mode) { move in
            let error = try #require(await move.run(), "the move did not report the older machine")
            #expect(error.message == CloudMoveStrings.outdatedMachine("Move VM"), "\(error.message)")
            #expect(move.calls().count == (mode == "syncOutdated" ? 1 : 2), "\(move.calls())")
            #expect(move.services.locateTab(move.tabID, onMachine: move.services.machines.local.machineID) != nil, "this Mac's tab closed though its chat did not move")
            #expect(move.services.cloud.moveRetries[move.key] == .update(machineID: "vm-move"))
        }
    }

    /// "Update Machine" (cx-rppd.13): after a move stopped on a machine whose cmux-tui is too old,
    /// only the person's button (an invocation from this app's own UI) updates the machine, through
    /// `cmux link machine update` with nothing but the machine's socket, then moves the chat there.
    /// The same argument from the CLI, MCP, a script or another client updates nothing.
    @Test func updateMachineUpdatesAnOutdatedMachineThenMovesTheChat() async throws {
        try await Self.withMove("updates") { move in
            #expect(await move.run() != nil, "the move did not report the older machine")
            #expect(move.services.cloud.moveRetries[move.key] == .update(machineID: "vm-move"))

            // The argument from anywhere but this app's own UI: never an update, only the move again.
            var performed: [ActionOrigin] = []
            for origin in [ActionOrigin.cli, .mcp, .script, .remote] {
                let before = move.calls().count
                let invocation = ActionInvocation(target: ActionTargetRef(kind: .tab, id: move.key),
                                                  arguments: [CloudMachineUpdate.argument: .bool(true), "path": .string(move.project.path),
                                                              "machine": .string("vm-move")],
                                                  origin: origin)
                // An origin the registry refuses outright updates nothing either.
                guard move.services.registry.perform(CloudMove.action, invocation: invocation) else { continue }
                performed.append(origin)
                // An origin the action holds may run nothing at all; the CLI's runs the move.
                let deadline = ContinuousClock.now + .seconds(origin == .cli ? 30 : 10)
                while move.calls().count < before + 2, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
                let ran = move.calls().dropFirst(before).map { Array($0.prefix(3)) }
                if origin == .cli { #expect(ran == [["link", "seed", "push"], ["link", "agent", "move"]], "\(ran)") }
                // The stop's own bookkeeping, after its last call.
                try? await Task.sleep(for: .milliseconds(300))
            }
            #expect(performed.contains(.cli), "the CLI's invocation never ran: \(performed)")
            #expect(!move.calls().contains { $0.prefix(3) == ["link", "machine", "update"] }, "an update ran: \(move.calls())")
            #expect(move.services.locateTab(move.tabID, onMachine: move.services.machines.local.machineID) != nil)

            // The toast's "Update Machine".
            let before = move.calls().count
            let update = ActionInvocation(target: ActionTargetRef(kind: .tab, id: move.key),
                                          arguments: [CloudMachineUpdate.argument: .bool(true), "path": .string(move.project.path), "machine": .string("vm-move")],
                                          origin: .user)
            #expect(move.services.registry.perform(CloudMove.action, invocation: update))
            let moved = try await move.read()
            let calls = Array(moved.calls.dropFirst(before))
            #expect(calls.first == ["link", "machine", "update", "--socket", move.vmSocket], "\(calls)")
            #expect(calls.dropFirst().map { Array($0.prefix(3)) } == [["link", "seed", "push"], ["link", "agent", "move"]], "\(calls)")
            #expect(moved.machineTab?.agentSession?.session == "chat-on-vm", "the chat did not move after the update")
            #expect(!moved.macStillHasTab)
        }
    }

    /// A machine too old to update in place says so and offers no button: retrying can't help.
    @Test func aMachineTooOldToUpdateSaysSoAndKeepsTheChat() async throws {
        try await Self.withMove("updateUnsupported") { move in
            #expect(await move.run() != nil)
            let update = ActionInvocation(target: ActionTargetRef(kind: .tab, id: move.key),
                                          arguments: [CloudMachineUpdate.argument: .bool(true), "path": .string(move.project.path), "machine": .string("vm-move")],
                                          origin: .user)
            #expect(move.services.registry.perform(CloudMove.action, invocation: update))
            let deadline = ContinuousClock.now + .seconds(30)
            while move.services.cloud.moveRetries[move.key] != nil, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
            #expect(move.services.cloud.moveRetries[move.key] == nil, "a machine too old to update offers a retry")
            let calls = move.calls()
            #expect(calls.last == ["link", "machine", "update", "--socket", move.vmSocket], "the move ran after a refused update: \(calls)")
            #expect(move.services.locateTab(move.tabID, onMachine: move.services.machines.local.machineID) != nil, "this Mac's tab closed though its chat did not move")
        }
    }

    /// When this Mac's own daemon is the one too old for the move, the machine is not blamed: the
    /// move fails with the CLI's own words and no machine update is suggested.
    @Test func anOutdatedDaemonOnThisMacIsNotBlamedOnTheMachine() async throws {
        try await Self.withMove("macOutdated") { move in
            let error = try #require(await move.run(), "the move did not stop")
            #expect(error.message != CloudMoveStrings.outdatedMachine("Move VM"), "\(error.message)")
            #expect(error.message.hasPrefix(CloudMoveStrings.moveFailed("")), "\(error.message)")
            #expect(!error.message.contains("update the machine"), "\(error.message)")
            #expect(move.services.locateTab(move.tabID, onMachine: move.services.machines.local.machineID) != nil)
        }
    }

    /// An agent's Move to Cloud (cmuxterm-hq#1874 slice 5): `cmux cloud move` from the chat's own
    /// agent moves nothing. It shows a card in that chat (Move, Not now, Always); a click that is no
    /// real gesture in the pane moves nothing either, and the person's Move runs the move above.
    @Test func anAgentsMoveAsksInItsChatAndOnlyThePersonsMoveMovesIt() async throws {
        try await Self.withMove("moves") { move in
            if let error = await move.runAsAgent() { Issue.record("the agent's ask was refused: \(error.code) \(error.message)") }
            let cards = try #require(await move.toolCards(), "the chat has no page")
            let card = try #require(cards.first, "no card in the chat")
            #expect(move.calls().isEmpty, "the agent's run moved the chat: \(move.calls())")
            #expect(Self.text(card, "state") == "ask")
            #expect(Self.actionIDs(card) == ["move", "notNow", "always"])
            let id = try #require(Self.text(card, "id"))

            // Page script can't answer for the person.
            #expect(await move.answer(id, "move", gesture: false)["ok"] as? Bool != true)
            #expect(move.calls().isEmpty, "a click without a gesture moved the chat")

            #expect(await move.answer(id, "move", gesture: true)["ok"] as? Bool == true)
            let moved = try await move.read()
            #expect(moved.calls.count == 2, "\(moved.calls)")
            #expect(moved.machineTab?.agentSession?.session == "chat-on-vm", "the person's Move did not move the chat")
            #expect(!moved.macStillHasTab)
        }
    }

    /// Not now leaves the chat on this Mac and takes the card away; an agent never brings a chat back.
    @Test func notNowKeepsTheChatAndAnAgentCantBringOneBack() async throws {
        try await Self.withMove("moves") { move in
            let refused = await move.runAsAgent("cloud bring-back")
            #expect(refused?.message.contains(CloudMoveAskStrings.bringBackIsPersons) == true, "an agent's Bring Back Local was not refused as one: \(String(describing: refused?.message))")
            if let error = await move.runAsAgent() { Issue.record("the agent's ask was refused: \(error.code) \(error.message)") }
            let card = try #require(await move.toolCards()?.first, "no card in the chat")
            let id = try #require(Self.text(card, "id"))
            #expect(await move.answer(id, "notNow", gesture: true)["ok"] as? Bool == true)
            #expect(await move.toolCards(waiting: false)?.isEmpty == true, "the card stayed after Not now")
            #expect(move.calls().isEmpty, "Not now moved the chat: \(move.calls())")
            #expect(move.services.locateTab(move.tabID, onMachine: move.services.machines.local.machineID) != nil)
        }
    }

    /// A card's text field.
    static func text(_ card: [String: CmuxNextSettings.JSONValue], _ key: String) -> String? {
        guard case .string(let value)? = card[key] else { return nil }
        return value
    }

    /// A card's buttons, by id.
    static func actionIDs(_ card: [String: CmuxNextSettings.JSONValue]) -> [String] {
        guard case .array(let list)? = card["actions"] else { return [] }
        return list.compactMap { value -> String? in
            guard case .object(let action) = value, case .string(let id)? = action["id"] else { return nil }
            return id
        }
    }

    // MARK: The harness

    /// One move's world: this Mac's daemon with a live chat tab, a Cloud machine on a second
    /// daemon, and the stand-in CLI.
    @MainActor
    final class Move {
        private(set) var services: AppServices
        private(set) var machine: CloudMachineSession
        /// Builds the relaunched app: a second app on the same daemons and defaults.
        var relaunched: (@MainActor () async throws -> (AppServices, CloudMachineSession))?
        let project: URL
        let workRoot: URL
        let log: URL
        let vmSocket: String
        var tabID = ""
        /// The chat tab's id on this Mac, as the app keys it.
        var key = ""
        /// The chat tab's surface on this Mac.
        var surface: UInt64 = 0

        init(services: AppServices, machine: CloudMachineSession, project: URL, workRoot: URL, log: URL, vmSocket: String) {
            self.services = services
            self.machine = machine
            self.project = project
            self.workRoot = workRoot
            self.log = log
            self.vmSocket = vmSocket
        }

        /// Quits this app as a quit keeping sessions does (its daemons and their chats keep
        /// running) and opens the relaunched app, which shows this Mac's tab again unless a move
        /// closed it (`tabClosed`). The quit app's work still running reaches no defaults, as a
        /// process that ended.
        func relaunch(tabClosed: Bool = false) async throws {
            let build = try #require(relaunched)
            services.cloud.move.ledger = nil
            services.daemon.shutdownConnection()
            machine.daemon.shutdownConnection()
            for controller in services.windows.controllers { controller.window?.close() }
            (services, machine) = try await build()
            let deadline = ContinuousClock.now + .seconds(60)
            func ready() -> Bool {
                machine.daemon.connection != nil && AgentTabStore.registryHost(of: machine.daemon) != nil
                    && (tabClosed || services.locateTab(tabID, onMachine: services.machines.local.machineID) != nil)
            }
            while !ready(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
            try #require(ready(), "the relaunched app did not reconnect, or does not show this Mac's chat tab")
            if !tabClosed { #expect(services.locateTab(tabID, onMachine: services.machines.local.machineID)?.0.id == key, "the relaunched app keys this Mac's chat tab differently") }
        }

        /// `cmux cloud move` on the chat tab, without waiting for it.
        func start() {
            let services = services, tabID = tabID, path = project.path
            Task { @MainActor in
                _ = await Self.send(services, ["action": .string("cloud move"), "cli": .bool(true), "origin": .string("cli"), "wait": .bool(true),
                                               "target": .string("tab:" + tabID), "args": .object(["path": .string(path)])])
            }
        }

        /// `cmux cloud move` on the chat tab; its error when it stopped.
        func run() async -> ControlError? {
            await send(["action": .string("cloud move"), "cli": .bool(true), "origin": .string("cli"), "wait": .bool(true),
                        "target": .string("tab:" + tabID), "args": .object(["path": .string(project.path)])])
        }

        /// `cmux <action>` on the chat tab, as the CLI sends it; its error when it stopped.
        func cli(_ action: String, args: [String: CmuxNextSettings.JSONValue] = [:]) async -> ControlError? {
            await send(["action": .string(action), "cli": .bool(true), "origin": .string("cli"), "wait": .bool(true),
                        "target": .string("tab:" + tabID), "args": .object(args)])
        }

        /// `action` as the chat's own agent runs it from its shell: the CLI names the agent's session
        /// as the caller (`CMUX_AGENT_SESSION`) and no target. Its error when it was refused.
        func runAsAgent(_ action: String = "cloud move") async -> ControlError? {
            // The chat's folder, as this Mac's acpmux reports it for the chat's session.
            services.agentTabs.localSessionHost = SessionFolderHost(folder: project.path)
            return await send(["action": .string(action), "cli": .bool(true), "origin": .string("cli"), "wait": .bool(true),
                        "caller": .object(["agent_session": .string("chat-live")])])
        }

        /// The chat's page's tool cards as the page gets them (its `toolCards` event), once there are
        /// some (or ten seconds passed); nil when the chat has no page.
        func toolCards(waiting: Bool = true) async -> [[String: CmuxNextSettings.JSONValue]]? {
            let deadline = ContinuousClock.now + .seconds(10)
            func cards() -> [[String: CmuxNextSettings.JSONValue]]? {
                guard let view = services.agentTabs.existingView(key) else { return nil }
                guard let event = AgentPanePageHost.currentEvents(view).first(where: { $0.kind == "toolCards" }), case .array(let list) = event.value else { return [] }
                return list.compactMap { value -> [String: CmuxNextSettings.JSONValue]? in
                    guard case .object(let card) = value else { return nil }
                    return card
                }
            }
            while waiting, cards()?.isEmpty != false, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
            return cards()
        }

        /// A click on `action` of card `card` in the chat's page, after a real click in the pane when `gesture`.
        func answer(_ card: String, _ action: String, gesture: Bool) async -> [String: Any] {
            guard let model = services.agentTabs.existingView(key)?.model else { return ["ok": false] }
            if gesture { model.transport.gestures.record() }
            return await model.respond(to: AgentPaneRequest(body: ["method": "chat.toolCard.respond", "params": ["id": card, "action": action]]))
        }

        private func send(_ params: [String: CmuxNextSettings.JSONValue]) async -> ControlError? {
            await Self.send(services, params)
        }

        private static func send(_ services: AppServices, _ params: [String: CmuxNextSettings.JSONValue]) async -> ControlError? {
            await CloudCLIActionRun(services: services)(params)
        }

        /// The stand-in CLI's calls so far, each as its arguments; not `link access` (a moved chat's
        /// file requests, polled on their own: ``CloudBringBackTests``).
        func calls() -> [[String]] {
            let lines = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            return lines.split(separator: "\n").map { $0.split(separator: "\u{1f}").map(String.init) }.filter { $0.prefix(2) != ["link", "access"] }
        }

        /// Both trees once the machine shows a chat and this Mac's tab is gone (or a minute passed).
        func read() async throws -> Moved {
            let deadline = ContinuousClock.now + .seconds(60)
            var moved = Moved()
            moved.surface = surface
            moved.macSocket = await services.daemon.connection?.endpoint?.socketPath ?? ""
            moved.machineStore = (AgentTabStore.registryHost(of: machine.daemon) ?? "").replacingOccurrences(of: "registry:", with: "")
            func machineChat() -> (TabModel, PaneModel)? {
                for workspace in machine.daemon.store.workspaces {
                    for pane in workspace.screens.flatMap(\.panes) {
                        if let tab = pane.tabs.first(where: { $0.agentSession != nil }) { return (tab, pane) }
                    }
                }
                return nil
            }
            while machineChat() == nil || services.locateTab(tabID, onMachine: services.machines.local.machineID) != nil, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            if let (tab, pane) = machineChat() {
                moved.machineTab = tab
                let daemon = services.machines.daemon(forTab: tab)
                moved.attachesThroughMachine = (try? services.machines.agentDaemon(forTab: tab)) === machine.daemon
                moved.badge = services.machines.machineBadge(daemon.machineID)
                if let key = machine.daemon.store.workspace(containing: pane.handle)?.key,
                   let listed = try await machine.daemon.connection?.listWorkspaces().workspaces.first(where: { $0.key == key }) {
                    moved.terminalFolders = listed.screens.flatMap(\.panes).flatMap(\.tabs).filter { $0.kind == .pty }.compactMap(\.cwd)
                }
            }
            moved.macStillHasTab = services.locateTab(tabID, onMachine: services.machines.local.machineID) != nil
            moved.calls = calls()
            moved.folderName = moved.calls.first?.last.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
            return moved
        }
    }

    /// A chat host that knows only the chat's folder, as this Mac's acpmux reports it.
    struct SessionFolderHost: AgentPaneHostProviding {
        let folder: String
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
        func sessionFolder(sessionId: String) async throws -> AgentPaneSessionFolder? { AgentPaneSessionFolder(cwd: folder, isLocal: true) }
    }

    struct Moved {
        var calls: [[String]] = []
        var macSocket = ""
        var surface: UInt64 = 0
        var folderName = ""
        var machineStore = ""
        var machineTab: TabModel?
        var attachesThroughMachine = false
        var badge: String?
        var terminalFolders: [String] = []
        var macStillHasTab = true
    }

    /// Runs `body` with a live chat tab on this Mac and a connected Cloud machine; the stand-in
    /// CLI answers as `mode` says (``Stop``'s raw values, or `moves`).
    private static func withMove(_ mode: String, _ body: (Move) async throws -> Void) async throws {
        let timer = PhaseTimer("move")
        let binary = try #require(SameTreeDaemonBinary.url)
        // A real path (no /tmp symlink): the daemon reports a terminal's folder as it launched it.
        let root = URL(fileURLWithPath: "/private/tmp/cn-move-\(UUID().uuidString.prefix(8).lowercased())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("proj", isDirectory: true)
        try FileManager.default.createDirectory(at: project.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let workRoot = root.appendingPathComponent("vm-home/work", isDirectory: true)
        try FileManager.default.createDirectory(at: workRoot, withIntermediateDirectories: true)
        let log = root.appendingPathComponent("cli.log")
        let cli = try standInCLI(in: root, log: log, mode: mode, vmState: root.appendingPathComponent("vm-state"))

        let environment: @Sendable () -> [String: String] = {
            ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": "/bin/sh", "TERM": "xterm-256color"]
        }
        let mac = DaemonLauncher(configuration: .init(binary: binary, session: "cn-move-mac-\(UUID().uuidString.prefix(6).lowercased())",
                                                      stateDirectory: root.appendingPathComponent("mac-state")), environment: environment)
        let vm = DaemonLauncher(configuration: .init(binary: binary, session: "cn-move-vm-\(UUID().uuidString.prefix(6).lowercased())",
                                                     stateDirectory: root.appendingPathComponent("vm-state")), environment: environment)
        _ = NSApplication.shared
        // The app's own defaults, as the app keeps them, for this run only.
        let suite = "cn-move-\(UUID().uuidString.prefix(8).lowercased())"
        let ledger = try #require(UserDefaults(suiteName: suite))
        defer { ledger.removePersistentDomain(forName: suite) }
        let vmSocket = try await vm.endpointProvider().socketPath
        timer.mark("vm-endpoint")
        func app() async throws -> (AppServices, CloudMachineSession) {
            let services = AppServices(environment: AppEnvironment.current([:]))
            AppActions.bind(services)
            services.windows.ordersWindowsIn = false
            services.cloud.move = CloudMoveSetup(cli: cli, workRoots: [workRoot.path], timeout: .seconds(5), ledger: ledger)
            services.daemon.start {
                DaemonConnection(configuration: DaemonConnection.Configuration(terminalEnvironment: nil), endpointProvider: mac.endpointProvider)
            }
            services.windows.restoreWhenLoaded()
            let machine = Self.machine(services, cli: cli, root: root)
            services.machines.add(machine)
            machine.daemon.start(remote: { vmSocket })
            return (services, machine)
        }
        let (services, machine) = try await app()
        let watches = [timer.watch("restored") { services.windows.restored }, timer.watch("mac-connected") { services.daemon.connection != nil }]
        defer { for watch in watches { watch.cancel() } }

        let move = Move(services: services, machine: machine, project: project, workRoot: workRoot, log: log, vmSocket: vmSocket)
        move.relaunched = app
        let result: Result<Void, any Error>
        do {
            try await openChat(move)
            timer.mark("chat-tab")
            try await body(move)
            timer.mark("body")
            result = .success(())
        } catch {
            result = .failure(error)
            timer.mark("body-threw")
        }
        await end(move.services.daemon)
        await end(move.machine.daemon)
        for controller in move.services.windows.controllers { controller.window?.close() }
        timer.mark("ended")
        try result.get()
    }

    /// Opens a live chat (with a session) in this Mac's first workspace, as a chat the app opened.
    private static func openChat(_ move: Move) async throws {
        let services = move.services, machine = move.machine
        let deadline = ContinuousClock.now + .seconds(60)
        func ready() -> Bool {
            services.daemon.store.workspaces.contains { $0.screens.contains { !$0.panes.isEmpty } }
                && machine.daemon.connection != nil && AgentTabStore.registryHost(of: machine.daemon) != nil
        }
        while !ready(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(100)) }
        try #require(ready(), "the daemons did not come up")
        let connection = try #require(services.daemon.connection)
        let pane = try #require(services.daemon.store.workspaces.first?.screens.first?.panes.first)
        let record = AgentSessionRef(host: AgentSessionRef.host(installID: "cn-move-test"), hostName: "This Mac", session: "chat-live", harness: "claude")
        let created = try await connection.request(NewConversationTabRequest(agentSession: record, pane: pane.handle))
        move.tabID = created.tabResourceID?.rawValue ?? "surface:\(created.surface.rawValue)"
        move.surface = created.surface.rawValue
        while services.locateTab(move.tabID, onMachine: services.machines.local.machineID) == nil, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        move.key = try #require(services.locateTab(move.tabID, onMachine: services.machines.local.machineID)?.0.id, "the chat tab did not appear")
    }

    /// A stand-in `cmux`: records each call's arguments (unit-separated). Like the real sync,
    /// `link seed push` creates the synced folder (not in `tabFailed`, so the machine's terminal
    /// can't start there; in `syncTimeout` it outlives the CLI timeout); `link agent move`
    /// answers as `mode` says. A move that answers ok also leaves what the machine daemon's own
    /// `agent-transfer-finish` would: the landed chat's record (`agent-transfer-landed.json` next
    /// to that daemon's registry in `vmState`), without which the daemon refuses a `registry:` tab
    /// naming the chat (cx-k21v).
    private static func standInCLI(in root: URL, log: URL, mode: String, vmState: URL) throws -> URL {
        let url = root.appendingPathComponent("cmux")
        let script = """
            #!/bin/sh
            line=""
            for arg in "$@"; do line="$line$(printf '\\037')$arg"; done
            printf '%s\\n' "${line#?}" >> '\(log.path)'
            case "$1 $2 $3" in
            "link seed push")
                [ '\(mode)' = syncTimeout ] && exec sleep 30
                if [ '\(mode)' = syncOutdated ]; then
                    echo '{"ok":false,"error":"the machine runs an older cmux-tui (0000old) without fs-v1; update the machine","error_code":"machine_outdated"}'
                    exit 1
                fi
                for target in "$@"; do :; done
                [ '\(mode)' = tabFailed ] || mkdir -p "$target"
                echo '{"ok":true,"written":1,"unchanged":0,"deleted":0,"skipped":0,"bytes":4}' ;;
            "link machine update")
                case '\(mode)' in
                updates) : > '\(root.path)/updated'; echo '{"ok":true,"updated":true,"build":"new","previous_build":"0000old"}' ;;
                updateUnsupported) echo '{"ok":false,"error":"too old to update in place","error_code":"machine_update_unsupported"}'; exit 1 ;;
                *) exit 64 ;;
                esac ;;
            "link agent move")
                case '\(mode)' in
                updates | updateUnsupported)
                    if [ ! -e '\(root.path)/updated' ]; then
                        echo '{"ok":false,"error":"the machine runs an older cmux-tui (0000old) without agent-transfer-v1; update the machine","error_code":"machine_outdated"}'
                        exit 1
                    fi ;;
                esac
                case '\(mode)' in
                unresolved) echo '{"ok":false,"error":"the move did not finish","error_code":"move_unresolved","retry_after_seconds":5}'; exit 1 ;;
                inProgress) echo '{"ok":false,"error":"the chat is moving","error_code":"move_in_progress"}'; exit 1 ;;
                badAnswer) echo 'thread main panicked'; exit 101 ;;
                timeout) exec sleep 30 ;;
                teamMachine) echo '{"ok":false,"error":"a team machine","error_code":"agent_session.team_vm_blocked"}'; exit 1 ;;
                outdated) echo '{"ok":false,"error":"the target daemon runs an older cmux-tui (0000old) without agent-transfer-v1","error_code":"machine_outdated","side":"target"}'; exit 1 ;;
                macOutdated) echo '{"ok":false,"error":"the source daemon runs an older cmux-tui (0000old) without agent-transfer-v1","error_code":"machine_outdated","side":"source"}'; exit 1 ;;
                *)
                    registry=$(find '\(vmState.path)' -name workspace-registry.sqlite3 -print | head -n 1)
                    [ -n "$registry" ] || exit 70
                    printf '[{"session":"chat-on-vm","landed_at_ms":%s000}]' "$(date +%s)" > "$(dirname "$registry")/agent-transfer-landed.json"
                    echo '{"ok":true,"session_id":"chat-on-vm","transfer_id":"tr-1","bytes":42,"resolved":false}' ;;
                esac ;;
            *) exit 64 ;;
            esac

            """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// A Cloud machine whose link this test replaces: its daemon is started on the second
    /// daemon's socket, so the link process never runs.
    static func machine(_ services: AppServices, cli: URL, root: URL) -> CloudMachineSession {
        let paths = CloudPaths(root: root.appendingPathComponent("cloud", isDirectory: true))
        let api = services.cloud.api
        let hub = CloudTunnelHub(api: api, paths: paths, binary: cli, deviceName: "cn-move-test")
        let link = CloudMachineLink(machineID: "vm-move", api: api, hub: hub, paths: paths, binary: cli, deviceName: "cn-move-test")
        return CloudMachineSession(machine: CloudMachine(id: "vm-move", displayName: "Move VM"), link: link,
                                   mainWork: MainWorkScheduler(budget: MainFrameBudget()))
    }

    /// Ends `daemon`'s connection and its daemon with its terminals, so no host outlives the test.
    static func end(_ daemon: DaemonService) async {
        guard let connection = daemon.connection else { return }
        daemon.shutdownConnection()
        await connection.close()
        _ = try? await connection.shutdownDaemon(endTerminals: true)
    }
}
