import CmuxNextBridge
import Foundation
@testable import CmuxNextCloudPlace
import Testing

/// The move's flow reports each step to Rust's reducer in order, and Cancel stops the move's Task only when the reducer says stop.
@MainActor struct CloudPlaceFlowsTests {
    /// A fake reducer: records each event's name, answers `stop` for a cancel when told to.
    nonisolated final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var names: [String] = []
        var stopOnCancel = true
        var events: [String] { lock.withLock { names } }

        func core(_ operation: String, _ request: Data) -> Data? {
            guard let object = try? JSONSerialization.jsonObject(with: request) as? [String: Any] else { return nil }
            if operation == "cloud_computer_status_live" { return nil } // not a move event
            if operation == "cloud_move_place_view" {
                let state = ["failed": "failed", "live": "live"][events.last ?? ""] ?? "moving"
                return Data(#"{"state":"\#(state)","n":\#(events.count)}"#.utf8)
            }
            let event = (object["event"] as? [String: Any])?["event"] as? String ?? ""
            lock.withLock { names.append(event) }
            let next = event == "cancel" && stopOnCancel ? "stop" : "go"
            return Data(#"{"flow":{"n":1},"next":"\#(next)"}"#.utf8)
        }
    }

    /// A fake app: one chat on this Mac, and how it answers a move (refused at once, or started).
    @MainActor final class Host: CloudPlaceHost {
        var chats = [CloudPlaceChat(id: "tab", session: "s", onCloud: false, turnRunning: false, turnStartedAtMs: nil, moving: false)]
        var refusal: String?
        var runs = 0
        /// How often the driver read the chats (each Auto evaluation reads them once).
        var reads = 0
        var turnEnded: (@MainActor (String) -> Void)?
        /// The signed-in Cloud account and team; `switchOnRun` changes it as the first move starts.
        var identity: CloudPlaceIdentity? = CloudPlaceIdentity(user: "u1", team: "t1", cloud: "https://cloud.test")
        var switchOnRun: CloudPlaceIdentity?
        func placeChats() -> [CloudPlaceChat] { reads += 1; return chats }
        func placeRun(_ chat: CloudPlaceChat, toCloud: Bool, machine: CloudPlaceMachine?, trigger: CloudPlaceFlows.Trigger, claims: CloudPlaceClaims) -> CloudPlaceRun {
            runs += 1
            if let next = switchOnRun { identity = next; switchOnRun = nil }
            if let refusal { return .refused(refusal) }
            return .started({})
        }
        func placeCloudSessions() -> [String] { [] }
        func placeOwnFacts(_ session: String) -> (before: String?, machines: [CloudPlaceOwnMachine]) { (nil, []) }
        func placeOnTurnEnded(_ handler: @escaping @MainActor (String) -> Void) { turnEnded = handler }
        func placeIdentity() -> CloudPlaceIdentity? { identity }
        func placeIdentityChangedReason() -> String { "account changed" }
    }

    private static func local(_ session: String) -> CloudPlaceChat {
        CloudPlaceChat(id: "tab-\(session)", session: session, title: session.uppercased(), onCloud: false, turnRunning: false, turnStartedAtMs: nil, moving: false)
    }

    private func rows(_ place: CloudPlaceFlows) -> [[String: Any]] {
        let object = place.evacuateJSON(canBringBack: 0).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        return object?["chats"] as? [[String: Any]] ?? []
    }

    /// Drivers a test started (their Auto watches stay registered with the system).
    static var started: [CloudPlaceDriver] = []

    private func flows(_ recorder: Recorder, liveLinger: Duration = .milliseconds(2500)) -> CloudPlaceFlows {
        let defaults = UserDefaults(suiteName: "CloudPlaceFlowsTests.\(UUID().uuidString)")!
        return CloudPlaceFlows(defaults: defaults, core: { recorder.core($0, $1) }, clock: { 1 }, liveLinger: liveLinger)
    }

    private func move(_ place: CloudPlaceFlows, _ session: String) -> Any? {
        place.placeJSON(session: session, onCloud: false, cloudName: nil)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["move"]
    }

    @Test func reportsEveryStepInOrder() throws {
        let recorder = Recorder()
        let place = flows(recorder)
        place.begin(session: "s", toCloud: true, trigger: .person, from: "Mac", to: "", cargo: .init())
        try place.advance("s", "machine")
        place.target("s", to: "vm")
        try place.advance("s", "sync")
        try place.advance("s", "freeze")
        place.step("s", "commit")
        place.step("s", "attach")
        place.step("s", "release")
        place.live("s")
        #expect(recorder.events == ["begin", "step", "target", "step", "step", "step", "step", "step", "live"])
        #expect(place.state(of: "s") == "live")
        #expect(place.placeJSON(session: "s", onCloud: true, cloudName: "vm") != nil)
    }

    @Test func cancelStopsTheTaskOnlyOnStop() throws {
        let recorder = Recorder()
        let place = flows(recorder)
        var stopped = 0
        place.begin(session: "s", toCloud: true, trigger: .evacuate, from: "Mac", to: "", cargo: .init())
        place.onCancel("s") { stopped += 1 }
        #expect(place.cancel("s") == .stop)
        #expect(stopped == 1)
        #expect(place.wasCancelled("s"))
        recorder.stopOnCancel = false
        place.begin(session: "t", toCloud: true, trigger: .person, from: "Mac", to: "", cargo: .init())
        place.onCancel("t") { stopped += 1 }
        #expect(place.cancel("t") == .go)
        #expect(stopped == 1)
    }

    /// A move the app refuses at once (no first message, no chat there) fails in the chat's flow, so the chat shows why and
    /// Retry, and the page's action answers with the reason; never the asked mode with nothing moving (review of #52230, F1).
    @Test func aMoveRefusedAtOnceFailsInTheChatsFlowAndAnswersWhy() {
        let recorder = Recorder(), host = Host()
        let place = flows(recorder)
        let driver = CloudPlaceDriver(place: place, host: host)
        host.refusal = "Send a first message, then move this chat."
        #expect(driver.setMode("cloud", tab: nil, session: "s") == .refused("Send a first message, then move this chat."))
        #expect(recorder.events == ["begin", "failed"])
        #expect(place.state(of: "s") == "failed")
        #expect(place.mode(of: "s") == "cloud")
        #expect(driver.retry(tab: nil, session: "s") == .refused("Send a first message, then move this chat."))
        host.refusal = nil
        #expect(driver.retry(tab: nil, session: "s") == nil)
        #expect(host.runs == 3)
    }

    /// At most one move per chat: while one runs, a second ask (the mode again, Retry) starts no copy and leaves its flow
    /// alone, and a move the app shows moving holds the same; once it ended the next starts (review of #52230, F2).
    @Test func oneMoveAtATimePerChat() async {
        let recorder = Recorder(), host = Host()
        let driver = CloudPlaceDriver(place: flows(recorder), host: host)
        #expect(driver.setMode("cloud", tab: nil, session: "s") == nil)
        // The first move's Task has not run yet (this test holds the main actor): it is still in flight.
        #expect(driver.setMode("cloud", tab: nil, session: "s") == .moving)
        #expect(driver.retry(tab: nil, session: "s") == .moving)
        #expect(host.runs == 1)
        var again: CloudPlaceRefusal? = .moving
        for _ in 0..<1000 where again == .moving {
            await Task.yield()
            again = driver.retry(tab: nil, session: "s")
        }
        #expect(again == nil)
        #expect(host.runs == 2)
        await Task.yield()
        host.chats[0].moving = true
        #expect(driver.setMode("cloud", tab: nil, session: "s") == .moving)
        #expect(driver.retry(tab: nil, session: "s") == .moving)
        #expect(host.runs == 2)
    }

    /// A mode picked while the chat moves is refused and leaves the mode alone: Local picked while a local chat moves to
    /// Cloud never reads `mode: local, at: cloud` once the move lands (review of #52230 at 37033a59, F1).
    @Test func aModePickedMidMoveIsRefusedAndKeepsTheMode() {
        let recorder = Recorder(), host = Host()
        let place = flows(recorder)
        let driver = CloudPlaceDriver(place: place, host: host)
        #expect(driver.setMode("cloud", tab: nil, session: "s") == nil)
        // The move's Task has not run yet (this test holds the main actor): it is in flight.
        #expect(driver.setMode("local", tab: nil, session: "s") == .moving)
        #expect(driver.setMode("auto", tab: nil, session: "s") == .moving)
        #expect(place.mode(of: "s") == "cloud")
        #expect(host.runs == 1)
    }

    /// Auto reads its chats as soon as it starts (chats kept on Auto across a relaunch), and again at once when a turn
    /// ends, not only at the next tick or system signal (review of #52230 at 37033a59, F2).
    @Test func autoEvaluatesAtStartAndWhenATurnEnds() async {
        let recorder = Recorder(), host = Host()
        let place = flows(recorder)
        place.setMode("auto", of: "s")
        let driver = CloudPlaceDriver(place: place, host: host)
        // Kept for the process: the signals' power watch holds an unretained pointer to them.
        Self.started.append(driver)
        driver.start()
        #expect(host.reads >= 1)
        let before = host.reads
        host.turnEnded?("s")
        for _ in 0..<1000 where host.reads == before { await Task.yield() }
        #expect(host.reads > before)
    }

    /// Auto's rule reads the prompts waiting behind a chat's turn: acpmux's summary names them (`queued`), and a chat
    /// carries that count to the rule instead of 0 (review of #52230 at 37033a59, F3).
    @Test func aChatsQueuedPromptsReachAuto() {
        #expect(AgentChatDetail.of(summary: ["sessionId": "s", "queued": 2])?.queued == 2)
        #expect(AgentChatDetail.of(summary: ["sessionId": "s"])?.queued ?? 0 == 0)
        #expect(CloudPlaceChat(id: "t", session: "s", onCloud: false, turnRunning: false, turnStartedAtMs: nil, moving: false, queued: 3).queued == 3)
    }

    /// A move that landed leaves the header once its card had its moment, so a remounted page never shows it again; a
    /// failed one keeps its card and Retry; the next move shows its own (review of #52230 at 37033a59, F4).
    @Test func aLandedMoveLeavesTheHeaderAndAFailedOneStays() async {
        let recorder = Recorder()
        let place = flows(recorder, liveLinger: .zero)
        place.begin(session: "s", toCloud: true, trigger: .person, from: "Mac", to: "", cargo: .init())
        place.live("s")
        place.finished("s")
        #expect(move(place, "s") != nil)
        for _ in 0..<1000 where move(place, "s") != nil { await Task.yield() }
        #expect(move(place, "s") == nil)
        #expect(place.state(of: "s") == "live")
        place.begin(session: "s", toCloud: false, trigger: .person, from: "vm", to: "Mac", cargo: .init())
        #expect(move(place, "s") != nil)

        place.begin(session: "t", toCloud: true, trigger: .person, from: "Mac", to: "", cargo: .init())
        place.failed("t", reason: "no machine")
        place.finished("t")
        for _ in 0..<50 { await Task.yield() }
        #expect(place.state(of: "t") == "failed")
        #expect(move(place, "t") != nil)
    }

    @Test func modesPersist() {
        let defaults = UserDefaults(suiteName: "CloudPlaceFlowsTests.\(UUID().uuidString)")!
        let first = CloudPlaceFlows(defaults: defaults)
        first.setMode("auto", of: "s")
        #expect(CloudPlaceFlows(defaults: defaults).mode(of: "s") == "auto")
    }

    @Test func dirtyCountSkipsARenamesSourcePath() {
        let out = Data(" M a.txt\0R  new.txt\0old.txt\0?? b.txt\0".utf8)
        #expect(CloudPlaceFlows.dirtyCount(porcelainZ: out) == 3)
        #expect(CloudPlaceFlows.dirtyCount(porcelainZ: Data()) == 0)
    }

    /// A home folder kept in git (a dotfiles `~/.git`): the move's count of a folder there is the repository's tracked
    /// changes; listing its untracked files would read every folder of the home folder (LAUNCH-NO-TCC-PROMPTS). A
    /// repository of its own below the home folder still counts its untracked files.
    @Test func dirtyFilesInTheHomeFoldersRepositoryCountTrackedChangesOnly() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("dirty-home-\(UUID().uuidString)", isDirectory: true)
        let tools = home.appendingPathComponent("tools", isDirectory: true)
        let app = home.appendingPathComponent("code/app", isDirectory: true)
        for folder in [tools, app, home.appendingPathComponent("Pictures/Photos Library.photoslibrary")] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: home) }
        func git(_ folder: URL, _ arguments: String...) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", folder.path, "-c", "user.name=t", "-c", "user.email=t@e.test", "-c", "commit.gpgsign=false",
                                 "-c", "core.hooksPath=/dev/null"] + arguments
            process.environment = ProcessInfo.processInfo.environment.merging(
                ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]) { _, ours in ours }
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0, "git \(arguments) in \(folder.path)")
        }
        try git(home, "init", "--quiet")
        try Data("export A=1\n".utf8).write(to: home.appendingPathComponent(".zshrc"))
        try git(home, "add", ".zshrc")
        try git(home, "commit", "--quiet", "-m", "dotfiles")
        try Data("export A=2\n".utf8).write(to: home.appendingPathComponent(".zshrc"))
        for file in ["notes.txt", "tools/run.py", "Pictures/Photos Library.photoslibrary/Photos.sqlite"] {
            try Data("x".utf8).write(to: home.appendingPathComponent(file))
        }
        try git(app, "init", "--quiet")
        try Data("x".utf8).write(to: app.appendingPathComponent("new.rs"))

        #expect(await CloudPlaceFlows.dirtyFiles(in: tools.path, homePath: home.path) == 1)
        #expect(await CloudPlaceFlows.dirtyFiles(in: home.path, homePath: home.path) == 1)
        #expect(await CloudPlaceFlows.dirtyFiles(in: app.path, homePath: home.path) == 1)
        // Another home folder: this repository's untracked files count (`notes.txt`, `tools/`, `Pictures/`, `code/`).
        #expect(await CloudPlaceFlows.dirtyFiles(in: tools.path, homePath: app.path) == 5)
    }

    @Test func evacuationShowsEachChatsStateAndCancelDropsTheQueue() throws {
        let place = flows(Recorder())
        place.beginEvacuation(direction: "toCloud", chats: [("a", "A"), ("b", "B"), ("c", "C")])
        place.evacuationPhase("a", .running)
        place.evacuationPhase("b", .running)
        place.evacuationPhase("b", .ended) // no flow was kept: read as failed, never as landed
        #expect(place.stopEvacuation() == ["a"])
        #expect(place.evacuationStopped)
        let object = try #require(place.evacuateJSON(canBringBack: 2).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        let states = (object["chats"] as? [[String: Any]])?.map { $0["state"] as? String }
        #expect(states == ["moving", "failed", "cancelled"])
        #expect(object["direction"] as? String == "toCloud" && object["canBringBack"] as? Int == 2 && object["elapsedMs"] != nil)
        place.evacuationPhase("a", .ended)
        #expect(place.evacuation?.endedMs != nil)
    }

    /// One bulk run at a time: a second Evacuate or Bring Back All while one runs is refused and leaves the first's
    /// progress alone (review of #52230 at 7edf8dd6, F3).
    @Test func aSecondBulkRunWhileOneRunsIsRefused() {
        let recorder = Recorder(), host = Host()
        host.chats = [Self.local("a"), Self.local("b")]
        let place = flows(recorder)
        let driver = CloudPlaceDriver(place: place, host: host)
        driver.planBulk = { _ in .init(moves: ["a", "b"], parallel: 1) }
        #expect(driver.evacuate(sessions: nil) == nil)
        // The run's worker has not run yet (this test holds the main actor): the run is going.
        #expect(place.evacuationRunning)
        #expect(driver.evacuate(sessions: nil) == .bulkRunning)
        #expect(driver.bringBackAll(sessions: ["a"]) == .bulkRunning)
        #expect(place.evacuation?.rows.map(\.session) == ["a", "b"])
    }

    /// A bulk run is bound to the Cloud account and team it started under: when they change mid-run no further chat
    /// moves, and the chats not started show failed with why rather than vanish (review of #52230 at 7edf8dd6, F2).
    @Test func aBulkRunStopsWhenTheCloudIdentityChanges() async {
        let recorder = Recorder(), host = Host()
        host.chats = [Self.local("a"), Self.local("b"), Self.local("c")]
        host.switchOnRun = CloudPlaceIdentity(user: "u2", team: "t2", cloud: "https://cloud.test")
        let place = flows(recorder)
        let driver = CloudPlaceDriver(place: place, host: host)
        driver.planBulk = { _ in .init(moves: ["a", "b", "c"], parallel: 1) }
        #expect(driver.evacuate(sessions: nil) == nil)
        for _ in 0..<1000 where place.evacuation?.endedMs == nil { await Task.yield() }
        #expect(place.evacuation?.endedMs != nil)
        #expect(host.runs == 1)
        let rows = rows(place).filter { ["b", "c"].contains($0["session"] as? String) }
        #expect(rows.map { $0["state"] as? String } == ["failed", "failed"])
        #expect(rows.map { $0["reason"] as? String } == ["account changed", "account changed"])
        // A new run under the new identity may start.
        #expect(driver.evacuate(sessions: nil) == nil)
    }

    /// The same identity throughout: every chat moves.
    @Test func aBulkRunUnderOneIdentityMovesEveryChat() async {
        let recorder = Recorder(), host = Host()
        host.chats = [Self.local("a"), Self.local("b")]
        let place = flows(recorder)
        let driver = CloudPlaceDriver(place: place, host: host)
        driver.planBulk = { _ in .init(moves: ["a", "b"], parallel: 1) }
        #expect(driver.evacuate(sessions: nil) == nil)
        for _ in 0..<1000 where place.evacuation?.endedMs == nil { await Task.yield() }
        #expect(host.runs == 2)
        #expect(!(place.evacuation?.stopped ?? true))
    }

    /// A run stopped for a reason shows its dropped chats failed with it; a Cancel shows them cancelled.
    @Test func aStopWithAReasonReadsFailedAndACancelReadsCancelled() {
        let place = flows(Recorder())
        place.beginEvacuation(direction: "toCloud", chats: [("a", "A")])
        #expect(place.stopEvacuation(reason: "account changed") == [])
        #expect(rows(place).first?["state"] as? String == "failed")
        #expect(rows(place).first?["reason"] as? String == "account changed")
        place.beginEvacuation(direction: "toCloud", chats: [("a", "A")])
        #expect(place.stopEvacuation() == [])
        #expect(rows(place).first?["state"] as? String == "cancelled")
        #expect(rows(place).first?["reason"] == nil)
    }

    @Test func idleEvacuateCarriesOnlyTheBringBackCount() throws {
        let place = flows(Recorder())
        #expect(place.evacuateJSON(canBringBack: 0) == nil)
        let object = try #require(place.evacuateJSON(canBringBack: 3).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(Set(object.keys) == ["canBringBack"])
    }

    /// The header's `place` carries Rust's `blocked` and `holders` for the control's facts, and sends the chat's own session.
    nonisolated final class SentControl: @unchecked Sendable { var request: [String: Any]? }

    @Test func placeCarriesTheControlsBlockedAndHoldersFromRust() throws {
        let sent = SentControl()
        let place = CloudPlaceFlows(defaults: UserDefaults(suiteName: "CloudPlaceFlowsTests.\(UUID().uuidString)")!, core: { operation, request in
            guard operation == "cloud_move_place_control" else { return nil }
            sent.request = try? JSONSerialization.jsonObject(with: request) as? [String: Any]
            return Data(#"{"blocked":{"why":"signed-out"},"holders":[{"session":"h","title":"Held"}]}"#.utf8)
        }, clock: { 1 })
        let chats = place.controlChats([CloudPlaceChat(id: "t", session: "h", title: "Held", onCloud: true, turnRunning: true, turnStartedAtMs: 5, moving: false)])
        let facts = CloudPlaceFlows.ControlFacts(signedIn: false, restoring: false, planKnown: true, planId: "next_plus", chats: chats)
        let object = try #require(place.placeJSON(session: "s", onCloud: false, cloudName: nil, control: facts)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect((object["blocked"] as? [String: Any])?["why"] as? String == "signed-out")
        #expect(((object["holders"] as? [[String: Any]])?.first)?["session"] as? String == "h")
        #expect(sent.request?["session"] as? String == "s")
        #expect(sent.request?["planId"] as? String == "next_plus")
        let chat = try #require((sent.request?["chats"] as? [[String: Any]])?.first)
        #expect(chat["pin"] as? String == "cloud" && chat["at"] as? String == "cloud" && chat["hasWork"] as? Bool == true)
        // No control facts, or an FFI with no op: the place is as before.
        let plain = try #require(place.placeJSON(session: "s", onCloud: false, cloudName: nil).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(plain["blocked"] == nil && plain["holders"] == nil)
    }

    /// A hybrid start's state rides on `place.start` as Rust answers it, read once per drivers' folder change (RFD 0078).
    @Test func placeCarriesTheHybridStart() throws {
        let defaults = UserDefaults(suiteName: "CloudPlaceFlowsTests.\(UUID().uuidString)")!
        let calls = Calls()
        let place = CloudPlaceFlows(defaults: defaults, core: { operation, request in
            guard operation == "cloud_hybrid_start" else { return nil }
            calls.add()
            let ask = try? JSONSerialization.jsonObject(with: request) as? [String: Any]
            return ask?["session"] as? String == "s" ? Data(#"{"start":{"cloud":"booting","sinceMs":5}}"#.utf8) : Data("{}".utf8)
        }, clock: { 1 })
        #expect(place.placeJSON(session: "s", onCloud: false, cloudName: nil).flatMap(Self.start) == nil) // no state folder: no read
        #expect(calls.count == 0)
        let sessions = FileManager.default.temporaryDirectory.appending(path: "hybrid-\(UUID().uuidString)/sessions")
        defer { place.watchStarts(state: nil) }
        let start = try #require(place.placeJSON(session: "s", onCloud: false, cloudName: nil, starts: sessions).flatMap(Self.start))
        #expect(start["cloud"] as? String == "booting")
        #expect(start["sinceMs"] as? Int == 5)
        _ = place.placeJSON(session: "s", onCloud: false, cloudName: nil)
        #expect(calls.count == 1) // the same revision reads once
        #expect(place.placeJSON(session: "t", onCloud: false, cloudName: nil).flatMap(Self.start) == nil) // no hybrid start: no key
    }

    nonisolated final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        var count: Int { lock.withLock { n } }
        func add() { lock.withLock { n += 1 } }
    }

    private static func start(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["start"] as? [String: Any]
    }

    /// Keep Running: the priority and its first time persist, reach Rust in the control facts, and Rust's `keep` reaches the header.
    @Test func keepRunningPersistsReachesRustAndCarriesItsKeep() throws {
        let defaults = UserDefaults(suiteName: "CloudPlaceFlowsTests.\(UUID().uuidString)")!
        let sent = SentControl()
        let core: CloudPlaceFlows.Core = { operation, request in
            guard operation == "cloud_move_place_control" else { return nil }
            sent.request = try? JSONSerialization.jsonObject(with: request) as? [String: Any]
            return Data(#"{"keep":{"priority":"high","pin":"auto","at":"local","lit":true,"used":1,"total":3,"waiting":false}}"#.utf8)
        }
        let first = CloudPlaceFlows(defaults: defaults, core: core, clock: { 1 })
        #expect(first.priority(of: "s") == "normal")
        first.setPriority("high", of: "s", nowMs: 42)
        first.setPriority("high", of: "s", nowMs: 99)  // already on: keeps its first time (the slot rule's order)
        let place = CloudPlaceFlows(defaults: defaults, core: core, clock: { 1 })
        #expect(place.priority(of: "s") == "high" && place.priorities["s"] == 42)
        let chats = place.controlChats([CloudPlaceChat(id: "t", session: "s", onCloud: false, turnRunning: false, turnStartedAtMs: nil, moving: false)])
        let facts = CloudPlaceFlows.ControlFacts(signedIn: true, restoring: false, planKnown: true, planId: "next_plus", chats: chats)
        let object = try #require(place.placeJSON(session: "s", onCloud: false, cloudName: nil, control: facts)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect((object["keep"] as? [String: Any])?["lit"] as? Bool == true)
        let chat = try #require((sent.request?["chats"] as? [[String: Any]])?.first)
        #expect(chat["priority"] as? String == "high" && chat["litAtMs"] as? Int == 42)
        place.setPriority("normal", of: "s")
        #expect(CloudPlaceFlows(defaults: defaults).priority(of: "s") == "normal")
        place.setPriority("sideways", of: "s")
        #expect(place.priorities.isEmpty)
    }
}
