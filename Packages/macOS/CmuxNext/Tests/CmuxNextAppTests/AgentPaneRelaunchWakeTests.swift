import CmuxNextActions
import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextTabs
import CmuxNextWakeups
import Foundation
import Testing

/// Leo 2026-10-20: "After nightlies, have the things running, but have the views go back to where
/// they were." A chat's composer held more than acpmux's draft text: its attachment chips and shell
/// mode with its unrun command. Hibernation kept them in memory only, so a relaunch (Restart to
/// Update, SIGTERM's Quit and keep sessions, Cmd-Q) dropped them. The quit's window step now saves
/// what every chat page holds, live or released, and the next launch hands it to each tab's first
/// page with its handshake, once.
@MainActor @Suite(.serialized)
struct AgentPaneRelaunchWakeTests {
    static let thisMac = "install:agent-pane-relaunch-wake-test"
    static let work = BackgroundWork(label: "test.relaunch-wake")

    /// A tab store of one run, as the App wires it: tab records in a tree, pages on a page that
    /// never loads (a loopback port nobody serves), the wake file of the tag's state directory.
    static func run(file: URL, records: [String: AgentSessionRef]) -> AgentTabStore {
        let tabs = AgentTabStore(build: nil, registry: ActionRegistry(),
                                 environment: [AgentPaneSource.devURLVariable: "http://127.0.0.1:9/"], showcase: true)
        tabs.localHost = thisMac
        tabs.relaunchWake = AgentPaneRelaunchWake(file: file)
        let tree = DaemonStore()
        tabs.lookup = { key in records[key].map { ($0, tree) } }
        return tabs
    }

    final class Asked { var count = 0 }

    static func ready(_ page: AgentPaneView) async throws -> [String: Any] {
        let reply = await page.model.respond(to: AgentPaneRequest(body: ["method": "ready"]))
        return try #require(reply["value"] as? [String: Any], "\(reply)")
    }

    @Test func aChatsComposerComesBackAfterARelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "relaunch-wake-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: AgentPaneRelaunchWake.fileName)
        let records = [
            "tab_shown": AgentSessionRef(host: Self.thisMac, hostName: "This Mac", session: "s-shown", harness: "claude"),
            "tab_released": AgentSessionRef(host: Self.thisMac, hostName: "This Mac", session: "s-released", harness: "claude"),
        ]
        let shownHeld = AgentPaneWakeState(
            attachments: [AgentPaneWakeState.Attachment(id: "a1", kind: "image", name: "shot.png", mimeType: "image/png", size: 4, data: "iVBO")],
            shell: true, shellText: "git status", scrollAnchor: AgentPaneScrollAnchor(rowId: "row-12", offset: 40))
        let releasedHeld = AgentPaneWakeState(shell: true, shellText: "make test")

        // This run: one chat's page is live, the other's let go (hibernation) and its tab kept what it held.
        let before = Self.run(file: file, records: records)
        let shown = try #require(before.view(for: "tab_shown"))
        _ = try await Self.ready(shown)
        before.wakeStates["tab_released"] = releasedHeld
        // A tab that left every tree (closed elsewhere) keeps nothing.
        before.wakeStates["tab_gone"] = AgentPaneWakeState(shell: true, shellText: "rm -rf build")
        before.relaunchWake.read = { page, _ in page === shown ? shownHeld : nil }
        // The quit's window step (every relaunch's quit goes through it).
        await before.relaunchWake.save(before.relaunchWakeStates())

        // The next run: each tab's first page gets its chat's composer back with its handshake.
        let after = Self.run(file: file, records: records)
        after.wakeStates = await after.relaunchWake.take(on: Self.work)
        #expect(after.wakeStates["tab_gone"] == nil, "a closed tab's composer was kept")
        let shownPage = try #require(after.view(for: "tab_shown"))
        let shownHandshake = try await Self.ready(shownPage)
        let shownWake = try #require(shownHandshake["wake"] as? [String: Any], "the live chat came back without its composer")
        let attachments = try #require(shownWake["attachments"] as? [[String: Any]])
        #expect(attachments.map { $0["name"] as? String } == ["shot.png"])
        #expect(attachments.first?["data"] as? String == "iVBO")
        #expect(shownWake["shell"] as? Bool == true)
        #expect(shownWake["shellText"] as? String == "git status")
        #expect((shownWake["scrollAnchor"] as? [String: Any])?["rowId"] as? String == "row-12")
        let releasedPage = try #require(after.view(for: "tab_released"))
        let releasedHandshake = try await Self.ready(releasedPage)
        let releasedWake = try #require(releasedHandshake["wake"] as? [String: Any], "the released chat came back without its composer")
        #expect(releasedWake["shellText"] as? String == "make test")

        // Handed back once: a crash after this launch never brings back chips already sent.
        let third = Self.run(file: file, records: records)
        third.wakeStates = await third.relaunchWake.take(on: Self.work)
        #expect(third.wakeStates.isEmpty)
    }

    /// A restored New Tab page with chips from the last quit never adopts the prewarmed spare (its
    /// handshake is long past): it gets a page of its own whose handshake carries them, and the
    /// state is gone from the store, so no later page brings it back.
    @Test func aRestoredNewTabPageGetsItsComposerInsteadOfTheSpare() async throws {
        let store = DaemonStore()
        var page = TabSnapshot(surface: 1, kind: .conversation, title: "about:blank", url: "about:blank")
        page.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: Self.thisMac))
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [PaneSnapshot(id: 1, tabs: [page])])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [screen])]))
        let tabs = AgentTabStore(build: nil, registry: ActionRegistry.standard(),
                                 environment: [AgentPaneSource.devURLVariable: "http://127.0.0.1:9"], showcase: true)
        tabs.localHost = Self.thisMac
        tabs.lookup = { key in store.tab(id: key)?.agentSession.map { ($0, store) } }
        let handler = NewTabPageHandler(open: { _, _ in }, jump: { _, _ in }, editShortcut: { _ in })
        tabs.firstPageNewTab = { _, _ in (AgentPaneNewTab(kind: .agent), handler) }
        tabs.blankChatHandler = { _ in handler }
        let spare = try #require(tabs.makeSpare(AgentPaneNewTab(kind: .agent)))
        tabs.takeSpare = { spare }
        let key = try #require(store.tab(surface: 1)?.id)
        tabs.wakeStates[key] = AgentPaneWakeState(shell: true, shellText: "npm run dev")

        let view = try #require(tabs.view(for: key))
        #expect(view !== spare, "the restored page adopted the spare and dropped its composer")
        #expect(tabs.wakeStates[key] == nil, "the restored state stayed in the store")
        let wake = try #require(try await Self.ready(view)["wake"] as? [String: Any], "the restored New Tab page lost its composer")
        #expect(wake["shellText"] as? String == "npm run dev")
    }

    /// A live page that does not answer in time, or whose own ready has not come yet (only a
    /// reconnect handshake), keeps the state it was built with instead of saving nothing.
    @Test func aPageThatDoesNotAnswerKeepsItsState() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "relaunch-wake-\(UUID().uuidString)")
        let records = ["tab_slow": AgentSessionRef(host: Self.thisMac, hostName: "This Mac", session: "s-slow", harness: "claude")]
        let tabs = Self.run(file: directory.appending(path: AgentPaneRelaunchWake.fileName), records: records)
        let held = AgentPaneWakeState(shell: true, shellText: "cargo test")
        tabs.wakeStates["tab_slow"] = held
        let page = try #require(tabs.view(for: "tab_slow"))
        _ = await page.model.respond(to: AgentPaneRequest(body: ["method": "ready", "params": ["reconnect": true]]))
        try #require(page.model.hasHandshake, "the reconnect handshake did not run")
        let asked = Asked()
        tabs.relaunchWake.read = { _, _ in
            asked.count += 1
            return nil
        }
        #expect(await tabs.relaunchWakeStates()["tab_slow"] == held, "a page that had not taken its state dropped it")
        #expect(asked.count == 0, "a page that had not taken its state was asked for one")

        // After its ready took the state, a page that does not answer in time keeps what it was given.
        _ = try await Self.ready(page)
        #expect(tabs.wakeStates["tab_slow"] == nil && page.model.pendingWake == nil)
        #expect(await tabs.relaunchWakeStates()["tab_slow"] == held, "a page that did not answer in time saved nothing over it")
        #expect(asked.count == 1)
    }

    /// Leo 2026-10-20: four screenshots pasted into a chat's composer were gone after a relaunch,
    /// while the draft's text came back. Their base64 went into the JSON, past a tab's 4 MB cap, so
    /// the tab's whole composer was dropped. Each attachment's bytes are now a file of their own in
    /// the state directory: the JSON stays small, the screenshots come back whole as the chips'
    /// thumbnails, and their files go once the launch takes them.
    @Test func pastedScreenshotsComeBackAfterARelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "relaunch-wake-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: AgentPaneRelaunchWake.fileName)
        let folder = directory.appending(path: AgentPaneRelaunchWake.attachmentsDirectoryName)
        let records = ["tab_chat": AgentSessionRef(host: Self.thisMac, hostName: "This Mac", session: "s-chat", harness: "claude")]
        // Four Retina screenshots of 1.5 MB each: 8 MB of base64 together.
        let shots = (1...4).map { index in
            var bytes = Data(repeating: UInt8(index), count: 1_500_000)
            bytes.replaceSubrange(0..<8, with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
            return bytes
        }
        let chips = shots.enumerated().map { index, bytes in
            AgentPaneWakeState.Attachment(id: "shot-\(index)", kind: "image", name: "Screenshot \(index).png",
                                          mimeType: "image/png", size: Double(bytes.count), data: bytes.base64EncodedString())
        }
        let link = AgentPaneWakeState.Attachment(id: "link", kind: "link", name: "notes", mimeType: "inode/directory", size: 0, path: "/tmp/notes")
        let held = AgentPaneWakeState(attachments: chips + [link])

        // This run: the chat's page holds the four screenshots when the app quits.
        let before = Self.run(file: file, records: records)
        let page = try #require(before.view(for: "tab_chat"))
        _ = try await Self.ready(page)
        before.relaunchWake.read = { _, _ in held }
        await before.relaunchWake.save(before.relaunchWakeStates())
        let size = try #require(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, "the quit saved no composer")
        #expect(size < 16 * 1024, "the screenshots' bytes went into the JSON (\(size) bytes)")
        let copies = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        #expect(copies.count == 4 && copies.allSatisfy { $0.pathExtension == "png" }, "\(copies.map(\.lastPathComponent))")
        let copied = try Set(copies.map { try Data(contentsOf: $0) })
        #expect(copied == Set(shots), "a copied screenshot's bytes changed")

        // The next run: the chat's first page gets the four screenshots back with its handshake.
        let after = Self.run(file: file, records: records)
        after.wakeStates = await after.relaunchWake.take(on: Self.work)
        #expect(!FileManager.default.fileExists(atPath: file.path) && !FileManager.default.fileExists(atPath: folder.path),
                "the launch left the saved composer behind, so a chip sent in this run could come back")
        let restoredPage = try #require(after.view(for: "tab_chat"))
        let restored = try #require(try await Self.ready(restoredPage)["wake"] as? [String: Any], "the chat came back without its screenshots")
        let attachments = try #require(restored["attachments"] as? [[String: Any]])
        #expect(attachments.map { $0["name"] as? String } == chips.map(\.name) + ["notes"])
        #expect(attachments.prefix(4).map { ($0["data"] as? String).flatMap { Data(base64Encoded: $0) } } == shots,
                "a screenshot came back without its bytes, so its chip has no thumbnail")
        #expect(attachments.last?["path"] as? String == "/tmp/notes", "a linked folder came back without its path")

        // Sent before the next quit: that quit saves nothing, and no copy is left behind.
        await after.relaunchWake.save([:])
        #expect(!FileManager.default.fileExists(atPath: file.path) && !FileManager.default.fileExists(atPath: folder.path))
    }

    /// A tab that does not fit the attachments' cap is not kept, and none of its files stay; the
    /// saves before this change (contents inline in the JSON) still come back.
    @Test func attachmentsPastTheCapLeaveNoFilesAndOldSavesStillRestore() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "relaunch-wake-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: AgentPaneRelaunchWake.fileName)
        let folder = directory.appending(path: AgentPaneRelaunchWake.attachmentsDirectoryName)
        let store = AgentPaneRelaunchWake(file: file)
        store.maximumAttachmentBytes = 8
        // The small tab's chip leaves room for one of this tab's two chips, not both: the first
        // one's file is written before the second does not fit.
        let huge = AgentPaneWakeState(attachments: (0..<2).map {
            AgentPaneWakeState.Attachment(id: "big-\($0)", kind: "image", name: "big.png", mimeType: "image/png", size: 3, data: "AAAA")
        })
        let small = AgentPaneWakeState(attachments: [
            AgentPaneWakeState.Attachment(id: "s", kind: "image", name: "s.png", mimeType: "image/png", size: 3, data: "AAAA"),
        ])
        await store.save(["tab_huge": huge, "tab_small": small])
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(left.count == 1, "the dropped tab's files stayed: \(left)")
        #expect(await store.take(on: Self.work) == ["tab_small": small])

        let inline = ["tab_old": AgentPaneWakeState(attachments: small.attachments, shell: true, shellText: "ls")]
        try JSONEncoder().encode(inline).write(to: file)
        #expect(await store.take(on: Self.work) == inline, "a save the last build wrote did not come back")
    }

    /// Slice (c) of the main-thread sweep: the launch read the states (up to 8 MB) and their attachments'
    /// files (up to 128 MB) on the main thread as it made the tab store.
    @Test func theSavedStatesAreReadOffTheMainThread() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "relaunch-wake-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: AgentPaneRelaunchWake.fileName)
        let held = AgentPaneWakeState(shell: true, shellText: "ls")
        await AgentPaneRelaunchWake(file: file).save(["tab_a": held])
        let probe = LaunchReadProbe()
        #expect(await AgentPaneRelaunchWake(file: file, reader: probe.reader).take(on: Self.work) == ["tab_a": held])
        #expect(probe.reads == [false], "the saved states were read on the main thread")
    }

    /// The launch reads the states off the main thread from its start: a page made before the read ends still
    /// gets its chat's composer with its first handshake (the handshake waits, never the main thread).
    @Test func aPageMadeBeforeTheReadEndsStillGetsItsComposer() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "relaunch-wake-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: AgentPaneRelaunchWake.fileName)
        let records = ["tab_chat": AgentSessionRef(host: Self.thisMac, hostName: "This Mac", session: "s-chat", harness: "claude")]
        let held = AgentPaneWakeState(shell: true, shellText: "make test")
        await AgentPaneRelaunchWake(file: file).save(["tab_chat": held])

        let probe = LaunchReadProbe(held: true)
        let tabs = Self.run(file: file, records: records)
        tabs.relaunchWake = AgentPaneRelaunchWake(file: file, reader: probe.reader)
        tabs.relaunchWake.begin(on: Self.work)
        let started = await probe.waitForStart()
        #expect(started, "the read never started")
        let page = try #require(tabs.view(for: "tab_chat"))
        // task-owner: the page's first ready; awaited below.
        let ready = Task { ((try await Self.ready(page))["wake"] as? [String: Any])?["shellText"] as? String }
        probe.release()
        #expect(try await ready.value == "make test", "a page made while the read ran lost its composer")
        #expect(probe.reads == [false], "the saved states were read on the main thread")
        #expect(!tabs.relaunchWake.mayHold("tab_chat"), "the state stayed in the store, so a later page could bring it back")
    }

    /// A chat whose page holds nothing saves nothing, and with nothing held the file goes.
    @Test func anEmptyComposerLeavesNoFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "relaunch-wake-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: AgentPaneRelaunchWake.fileName)
        let store = AgentPaneRelaunchWake(file: file)
        await store.save(["tab_a": AgentPaneWakeState(shell: true, shellText: "ls")])
        #expect(FileManager.default.fileExists(atPath: file.path), "a held shell command was not saved")
        await store.save(["tab_a": AgentPaneWakeState()])
        #expect(!FileManager.default.fileExists(atPath: file.path), "an empty composer left a file")
    }
}
