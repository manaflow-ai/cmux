@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Foundation
import Observation
import Testing

/// The row of the suite for a hold of the New Tab key while the daemon's answers wait (decision of 2026-11-17): a
/// print of what the keys and the answers write in the pane's tab list and map in its strip, for 3 sizes of the hold.
extension NewTabKeySessionWalkTests {
    /// The daemon's side of each creation: it waits here until the test answers it or refuses it.
    @MainActor final class HeldAnswers {
        typealias Answer = (created: AgentTabCreated, sequence: UInt64?)

        /// One creation that waits: its pane, the record of its tab and its transaction.
        struct Ask {
            let pane: PaneID
            let record: AgentSessionRef
            let transaction: ClientTransactionID
        }

        /// The creations that asked, in the order of their asks.
        private(set) var asks: [Ask] = []
        private var waiting: [CheckedContinuation<Answer?, Never>?] = []

        func wait(_ ask: Ask) async throws -> Answer {
            let given = await withCheckedContinuation { (one: CheckedContinuation<Answer?, Never>) in
                asks.append(ask)
                waiting.append(one)
            }
            guard let given else { throw CancellationError() }
            return given
        }

        /// Answers the creation at `index` one time. Nil refuses it, as a daemon that is gone does.
        func answer(_ index: Int, with answer: Answer?) {
            guard waiting.indices.contains(index), let one = waiting[index] else { return }
            waiting[index] = nil
            one.resume(returning: answer)
        }

        /// Each creation ends before the window closes.
        func refuseTheRest() {
            for index in waiting.indices { answer(index, with: nil) }
        }
    }

    /// Counts each write of one pane's tab list. A write wakes the watcher, which counts it and watches again in the
    /// same call, so 2 writes of one turn are 2.
    @MainActor final class TabListWrites {
        private(set) var count = 0
        private let pane: PaneModel

        init(_ pane: PaneModel) {
            self.pane = pane
            watch()
        }

        private func wrote() {
            count += 1
            watch()
        }

        private func watch() {
            withObservationTracking { _ = pane.tabs } onChange: { MainActor.assumeIsolated { self.wrote() } }
        }
    }

    /// The strip maps since `before` by their call site (the file and the line of the caller), for each pane.
    static func stripMapSites(since before: [String: Int]) -> [String] {
        var bySite: [String: Int] = [:]
        for (key, runs) in DebugLayoutCounters.sources where key.hasPrefix("snapshot") {
            let more = runs - (before[key] ?? 0)
            guard more > 0, let site = key.split(separator: " ").last else { continue }
            bySite[String(site), default: 0] += more
        }
        return bySite.map { "\($0.key): \($0.value)" }.sorted()
    }

    /// The report of a hold of the New Tab key with the daemon's answers held: the keys, each in its own turn of the
    /// main actor, then the answers one by one, each as the daemon gives it (the `tab-added` event with the creation's
    /// transaction, then the reply). For 10, 30 and 93 keys it prints the writes of the pane's tab list, the maps of
    /// its strip and the call sites of those maps (the pane's own observer is one site).
    ///
    /// A print with no bound (decision of 2026-11-17): it is the count at the decision's date, not a rule. At that
    /// date the store takes the stand-in tab of each waiting creation out of its pane and puts it in again at each
    /// store event. The 3 sizes show by a run how the counts grow with the hold. No frame runs here, so no page view
    /// is made: the counts are the store's and the strip's.
    ///
    /// The conditions are of the model only: each key's creation waits, each answer names its tab, and after the last
    /// answer the pane has no stand-in tab and one tab more for each key.
    @Test func aHoldOfTheNewTabKeyWithHeldAnswersReportsTheWritesOfThePanesTabList() async throws {
        for keys in [10, 30, 93] { try await Self.holdWithHeldAnswers(keys) }
    }

    static func holdWithHeldAnswers(_ keys: Int) async throws {
        try await Self.withPane { start in
            let store = start.services.machines.local.store
            let model = start.pane.pane
            let workspace = try #require(store.workspace(containing: model.handle), "setup: the keys' pane has no workspace")
            let holder = workspace.screens.first(where: { screen in screen.panes.contains(where: { $0.handle == model.handle }) })
            let screen = try #require(holder, "setup: the keys' pane has no screen")
            let answers = HeldAnswers()
            defer { answers.refuseTheRest() }
            start.services.agentTabs.create = { pane, _, record, _, transaction, _ in
                try await answers.wait(HeldAnswers.Ask(pane: pane, record: record, transaction: transaction))
            }
            let writes = TabListWrites(model)
            let tabsBefore = model.tabs.count
            let head = "new tab hold, \(start.workspaces) workspaces, \(keys) keys with the answers held, no frame"

            // The keys, each in its own turn.
            _ = start.visits.takeByWorkspace()
            let sitesAtKeys = DebugLayoutCounters.sources
            let (writesAtKeys, mapsAtKeys) = (writes.count, start.pane.debugSnapshotRuns)
            var made = 0
            var eachKey: [Int] = []
            for _ in 0..<keys {
                let at = writes.count
                made += Self.newTab(start).made
                await LargeSessionWindowFixture.drainMain()
                eachKey.append(writes.count - at)
            }
            let keyFeed = start.visits.takeByWorkspace()[workspace.id] ?? 0
            let standIns = model.tabs.filter { ProvisionalTab.isProvisional(surface: $0.surface) }.count
            let keyMaps = start.pane.debugSnapshotRuns - mapsAtKeys
            let keyWrites = "\(writes.count - writesAtKeys) times (the first key \(eachKey.first ?? -1), the last key \(eachKey.last ?? -1))"
            print("\(head): the keys added \(made) tabs and \(answers.asks.count) creations wait with \(standIns) stand-in tabs; "
                + "the keys wrote the pane's tab list \(keyWrites) and mapped its strip \(keyMaps) times; "
                + "the strip maps by call site: \(Self.stripMapSites(since: sitesAtKeys))")
            #expect(made == keys && answers.asks.count == keys,
                    "the model: \(keys) New Tab keys added \(made) tabs and \(answers.asks.count) creations wait")

            // The answers one by one: the daemon's event with the creation's transaction, then its reply.
            var sequence = max(store.appliedSequence, store.snapshotBarrier)
            let sitesAtAnswers = DebugLayoutCounters.sources
            let (writesAtAnswers, mapsAtAnswers) = (writes.count, start.pane.debugSnapshotRuns)
            var eachAnswer: [Int] = []
            var eachEvent: [Int] = []
            var applyTimes: [Double] = []
            var unnamed = 0
            for (index, ask) in answers.asks.enumerated() {
                let at = writes.count
                sequence += 1
                let surface = SurfaceID(rawValue: 5_000_000 + UInt64(index))
                var entity = TabSnapshot(surface: surface, tabResourceID: ResourceID(rawValue: "tab_held_\(index)"), kind: .conversation,
                                         title: "about:blank", browserRenderer: "frontend")
                entity.conversation = ConversationTabRef(agentSession: ask.record)
                let added = TabDelta(workspace: workspace.handle, screen: screen.handle, pane: ask.pane, surface: surface, index: nil,
                                     entity: entity, clientTransactionID: ask.transaction)
                let began = ContinuousClock.now
                store.apply(batch: [DaemonEventEnvelope(sequence: sequence, event: .tabAdded(added))])
                applyTimes.append(Self.milliseconds(since: began))
                eachEvent.append(writes.count - at)
                var reply: HeldAnswers.Answer?
                if let tab = store.tab(surface: surface) {
                    let settled: UInt64? = sequence
                    reply = (created: AgentTabCreated(key: tab.id, surface: surface), sequence: settled)
                } else {
                    unnamed += 1
                }
                answers.answer(index, with: reply)
                await LargeSessionWindowFixture.drainMain()
                eachAnswer.append(writes.count - at)
            }
            let answerFeed = start.visits.takeByWorkspace()[workspace.id] ?? 0
            let left = model.tabs.filter { ProvisionalTab.isProvisional(surface: $0.surface) }.count
            let more = model.tabs.count - tabsBefore
            let applySum = String(format: "%.2f", applyTimes.reduce(0, +))
            let applyFirst = String(format: "%.2f", applyTimes.first ?? -1), applyLast = String(format: "%.2f", applyTimes.last ?? -1)
            let answerMaps = start.pane.debugSnapshotRuns - mapsAtAnswers
            let firstAnswer = "the first answer \(eachAnswer.first ?? -1), of them \(eachEvent.first ?? -1) in its event's apply"
            let lastAnswer = "the last answer \(eachAnswer.last ?? -1), of them \(eachEvent.last ?? -1) in its event's apply"
            print("\(head): the \(eachAnswer.count) answers one by one wrote the pane's tab list \(writes.count - writesAtAnswers) times "
                + "(\(firstAnswer); \(lastAnswer)) and mapped its strip \(answerMaps) times; "
                + "the strip maps by call site: \(Self.stripMapSites(since: sitesAtAnswers))")
            let applies = "\(applySum) ms in sum (the first \(applyFirst) ms, the last \(applyLast) ms; a Debug build, no daemon, no page)"
            print("\(head): the store's apply of the answers' events took \(applies); the places feed mapped the pane's workspace "
                + "\(keyFeed) times at the keys and \(answerFeed) times at the answers; stand-in tabs left: \(left); "
                + "the pane has \(more) tabs more than before the hold; answers with no tab to name: \(unnamed)")
            #expect(left == 0 && more == keys && unnamed == 0,
                    "the model: after the answers the pane has \(left) stand-in tabs and \(more) tabs more for \(keys) keys; "
                        + "\(unnamed) answers named no tab")
        }
    }
}
