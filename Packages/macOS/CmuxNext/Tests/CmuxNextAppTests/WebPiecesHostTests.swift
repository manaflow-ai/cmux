import CmuxNextPages
@testable import CmuxNextUpdater
@testable import CmuxNextWebUpdates
import Foundation
import Testing

/// The app as the host of `cmux app web-pieces` (WebUpdates+Pieces.swift): every decision is the
/// CLI's; the app only acts on its answer. A refused active update is rolled back, the launch
/// restores the switched-out pieces without saving a roll back, an answer to a state that moved
/// on is dropped, and the updater asks whether an update is refused before it takes it.
@Suite(.serialized) @MainActor struct WebPiecesHostTests {
    /// A stand-in for the bundled `cmux`: what it was asked and its answers, in order (nil once
    /// they run out: a failed run).
    nonisolated final class CLI: @unchecked Sendable {
        var answers: [Data]
        var asked: [[String]] = []
        /// Runs before each answer (a test moves the updater on there).
        var during: (@Sendable () async -> Void)?

        init(_ answers: [Data]) { self.answers = answers }

        func run(_ words: [String]) async -> Data? {
            asked.append(words)
            await during?()
            return answers.isEmpty ? nil : answers.removeFirst()
        }
    }

    /// An updater that serves a kept update of every-merge.
    static func serving(in root: URL) async throws -> (WebUpdater, WebUpdatePointer) {
        let (archive, pointer) = try await WebUpdateStoreTests.makeArchive(in: root)
        let server = WebUpdaterTests.Server()
        server.archive = archive
        server.pointer = try WebUpdaterTests.pointerData(pointer)
        let store = WebUpdateStore(base: root.appending(path: "store", directoryHint: .isDirectory))
        let updater = WebUpdaterTests.updater(server, store: store)
        await updater.check()
        #expect(updater.state.active == pointer)
        return (updater, pointer)
    }

    static func refusing(_ key: String) -> Data {
        WebPiecesAnswerTests.answer(paneServe: "live", paneUpdate: key, refusedActive: true)
    }

    static let nothingSwitched = WebPiecesAnswerTests.answer(paneServe: "live", paneUpdate: nil)

    @Test func aRefusedActiveUpdateIsRolledBack() async throws {
        let root = try WebUpdateStoreTests.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let (updater, pointer) = try await Self.serving(in: root)
        let cli = CLI([Self.refusing(pointer.key), Self.nothingSwitched])
        let web = WebUpdates()
        let refused = await web.readPiecesNow(updater, { await cli.run($0) }, offline: false, launch: false)
        #expect(!refused)
        // Rolled back like `updates.web.rollback`: the bundled web, and the update never taken again.
        #expect(updater.state.active == nil)
        #expect(updater.store.readState().active == nil)
        #expect(updater.store.readState().floor >= pointer.committedAt)
        // Asked with the refused update active, then again offline with none.
        #expect(cli.asked.count == 2)
        #expect(cli.asked.first?.contains(pointer.key) == true)
        #expect(cli.asked.first?.contains("--offline") == false)
        #expect(cli.asked.last?.contains("--offline") == true)
        #expect(cli.asked.last?.contains("--active") == false)
        #expect(web.pieces?.refusedActive == false)
    }

    @Test func theLaunchRestoresThePiecesAndLeavesTheRollBackToTheNextRead() async throws {
        let root = try WebUpdateStoreTests.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let (updater, pointer) = try await Self.serving(in: root)
        let cli = CLI([Self.refusing(pointer.key), WebPiecesAnswerTests.answer(paneServe: "bundled", paneUpdate: nil)])
        let web = WebUpdates()
        web.piecesCLI = { await cli.run($0) }
        // Nothing was switched out when cmux last ran: the launch runs no CLI.
        #expect(!(await web.restorePieces(updater)))
        #expect(cli.asked.isEmpty)

        // A piece was: the launch asks offline. A refused active update is reported (the launch
        // serves the bundled web) but not rolled back here.
        await WebUpdates.keep([], switched: true, in: updater.store)
        #expect(await web.restorePieces(updater))
        #expect(cli.asked.count == 1)
        #expect(cli.asked.first?.contains("--offline") == true)
        #expect(updater.state.active == pointer)
        #expect(web.pieces == nil)

        // The piece switched to the bundle stays out from the first page on.
        defer { _ = WebBundleOverlay.shared.setSwitches([:]) }
        #expect(!(await web.restorePieces(updater)))
        #expect(web.pieces?.switched.keys.sorted() == ["agent-pane"])
        #expect(WebBundleOverlay.shared.switches == [WebPiecesAnswerTests.pane: nil])
        #expect(await WebUpdates.hasKept(updater.store))
        #expect(updater.state.active == pointer)
    }

    @Test func anAnswerToAStateThatMovedOnIsDropped() async throws {
        let root = try WebUpdateStoreTests.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let (updater, pointer) = try await Self.serving(in: root)
        let web = WebUpdates()

        // The channel changed while the CLI ran: its answer is not acted on.
        let cli = CLI([Self.refusing(pointer.key), Self.refusing(pointer.key)])
        cli.during = { await MainActor.run { updater.channel = .nightly } }
        #expect(!(await web.readPiecesNow(updater, { await cli.run($0) }, offline: false, launch: false)))
        #expect(cli.asked.count == 1)
        #expect(updater.state.active == pointer)
        #expect(web.pieces == nil)

        // A drill started while the CLI ran: dropped too.
        updater.channel = .everyMerge
        cli.during = { await MainActor.run { web.piecesDrill = true } }
        #expect(!(await web.readPiecesNow(updater, { await cli.run($0) }, offline: false, launch: false)))
        #expect(cli.asked.count == 2)
        #expect(updater.state.active == pointer)
        #expect(web.pieces == nil)
    }

    @Test func theUpdaterAsksTheCLIWhetherAnUpdateIsRefused() async throws {
        let root = try WebUpdateStoreTests.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let (updater, pointer) = try await Self.serving(in: root)
        let web = WebUpdates()
        // No CLI: nothing is refused.
        #expect(!(await web.piecesRefuse(pointer, updater)))

        let cli = CLI([Data("{\"refused\":true,\"serial\":4}\n".utf8), Data("{\"refused\":false,\"serial\":4}\n".utf8),
                       Data("usage: cmux app web-pieces\n".utf8)])
        web.piecesCLI = { await cli.run($0) }
        #expect(await web.piecesRefuse(pointer, updater))
        #expect(cli.asked.first == ["app", "web-pieces", "refused", "--state", updater.store.base.path,
                                    "--channel", "every-merge", "--key", pointer.key])
        #expect(!(await web.piecesRefuse(pointer, updater)))
        // An answer that does not parse, or none: not refused here.
        #expect(!(await web.piecesRefuse(pointer, updater)))
        // A drill reads its own state.
        web.piecesDrill = true
        #expect(!(await web.piecesRefuse(pointer, updater)))
        #expect(cli.asked.last == ["app", "web-pieces", "refused",
                                   "--state", updater.store.base.appending(path: "pieces-drill", directoryHint: .isDirectory).path,
                                   "--channel", "drill-every-merge", "--key", pointer.key])
    }
}
