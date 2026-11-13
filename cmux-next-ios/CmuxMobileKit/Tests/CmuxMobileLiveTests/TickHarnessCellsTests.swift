@testable import CmuxMobileFeed
import CmuxMobileModel
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

// Tick cells of the iOS reliability matrix (`axis: tick` in
// cmux-next-ios/reliability-matrix/cells.json): 10,000 operations each, under
// seeded faults, on virtual time (TickHarness.swift). Each prints one MATRIX
// line with the virtual time covered and the wall time spent.
//
// Leo, 2026-11-10: "[forget] soaks we just slam shit and artificially tick
// stuff into oblivion" (connectivity, CPU, RAM, disk).

private let studio = LinkMachine.Target(macID: "m1", name: "Studio", isOnline: true)

// MARK: Reconnects

/// What the reconnect world schedules: the machine's own events, and the
/// network going and coming back.
private enum LinkTick {
    case machine(LinkMachine.Event)
    case networkDown
    case networkUp
}

/// One reconnect run's results.
private struct ReconnectRun {
    var drops = 0
    var dials = 0
    var staleIgnored = 0
    /// Each outage's reconnect time after the network came back, and its bound.
    var worstOverBound: Duration = .zero
    var worst: Duration = .zero
    var reconnects: [Duration] = []
    var excessDials = 0
    var staleChangedPhase = 0
    var endedConnected = false
    var virtual: Duration = .zero
    var faults = TickFaults.Counts()
    var trace = TickTrace()
}

/// Runs `LinkMachine` through `drops` link losses. Each outage lasts
/// 100 ms to 8 h (log-uniform). Dials on a down network fail at once or
/// hang until their 25 s timeout (a dead path); dials on an up network go
/// through the scripted transport: lost (timeout), late, duplicated. Most
/// returns of the network come with a path change (`networkChanged`), the
/// rest (a captive portal, a VPN) only with the retry timer. The app goes to
/// the background and back, and presence blips, at random.
private func runReconnects(drops target: Int, seed: UInt64) -> ReconnectRun {
    var random = TickRandom(seed: seed)
    var clock = TickClock<LinkTick>()
    var machine = LinkMachine(transport: .wireGuard)
    var run = ReconnectRun()
    let faults = TickFaults(drop: 0.03, duplicate: 0.03, reorder: 0.03)
    let heartbeat = LinkController.heartbeat + LinkController.probeTimeout

    var networkUp = true
    var backAt: Duration?
    var pathChanged = true
    var outage: Duration = .zero
    var dialsThisOutage = 0
    // Fault time that the bound allows for, since the network came back.
    var slack: Duration = .zero

    func handle(_ event: LinkMachine.Event) {
        let before = machine.phase
        let generation = machine.generation
        let effects = machine.handle(event)
        run.trace.add(clock.now.tickMilliseconds)
        run.trace.add(phaseCode(machine.phase))
        switch event {
        case .dialSucceeded(let gen, _), .dialFailed(let gen, _), .retryDue(let gen), .linkDropped(let gen, _), .probeFailed(let gen, _):
            if gen != generation {
                run.staleIgnored += 1
                if machine.phase != before { run.staleChangedPhase += 1 }
            }
        default:
            break
        }
        if !before.isConnected, machine.phase.isConnected {
            if networkUp, let back = backAt {
                let took = clock.now - back
                // Without faults: a path change redials within the settle and
                // a dial; without one, a dial hung on the dead path times out,
                // then the longest backoff step and a dial.
                let base: Duration = pathChanged ? .seconds(2) : faults.timeout + .seconds(30) + faults.latency.upperBound
                run.reconnects.append(took)
                run.worst = max(run.worst, took)
                run.worstOverBound = max(run.worstOverBound, took - (base + slack))
                backAt = nil
                // Backoff: an outage of T seconds costs at most T/15 + 10 dials.
                if Double(dialsThisOutage) > outage.tickSeconds / 15 + 10 { run.excessDials += 1 }
                if run.drops < target {
                    clock.schedule(.networkDown, after: random.logDuration(Duration.seconds(1)...(.seconds(600))))
                }
            } else if !networkUp {
                // A dial that resolved after the network went: the heartbeat finds it.
                let gen = machine.generation
                clock.schedule(.machine(.probeFailed(generation: gen, reason: "timeout")), after: heartbeat)
            }
        }
        for effect in effects {
            switch effect {
            case .dial(let gen, _, _):
                run.dials += 1
                dialsThisOutage += 1
                if !networkUp {
                    if random.chance(0.3) {
                        clock.schedule(.machine(.dialFailed(generation: gen, reason: "timeout")), after: faults.timeout)
                    } else {
                        clock.schedule(.machine(.dialFailed(generation: gen, reason: "network unreachable")), after: random.duration(Duration.milliseconds(50)...(.seconds(2))))
                    }
                    continue
                }
                switch faults.deliver(&random, counts: &run.faults) {
                case .lost:
                    if backAt != nil { slack += faults.timeout + .seconds(30) + faults.latency.upperBound }
                    clock.schedule(.machine(.dialFailed(generation: gen, reason: "timeout")), after: faults.timeout)
                case .delivered(let delays):
                    if backAt != nil, let first = delays.first, first > faults.latency.upperBound { slack += first }
                    for delay in delays {
                        clock.schedule(.machine(.dialSucceeded(generation: gen, path: .direct)), after: delay)
                    }
                }
            case .scheduleRetry(let gen, let after):
                clock.schedule(.machine(.retryDue(generation: gen)), after: after)
            case .close, .probe, .quickProbe:
                break
            }
        }
    }

    clock.schedule(.machine(.target(studio)), at: .zero)
    clock.schedule(.networkDown, at: .seconds(5))
    while let tick = clock.next(until: .seconds(Int64(target) * 40_000)) {
        switch tick {
        case .machine(let event):
            handle(event)
        case .networkDown:
            run.drops += 1
            networkUp = false
            dialsThisOutage = 0
            slack = .zero
            outage = random.logDuration(Duration.milliseconds(100)...(.seconds(8 * 3600)))
            pathChanged = random.chance(0.8)
            // The link notices at once (a reset) or at the heartbeat.
            let gen = machine.generation
            if random.chance(0.5) {
                handle(.linkDropped(generation: gen, reason: "network lost"))
            } else {
                clock.schedule(.machine(.probeFailed(generation: gen, reason: "timeout")), after: heartbeat)
            }
            // Noise during the outage: the app backgrounds and resumes, presence blips.
            if random.chance(0.2) {
                let away = random.duration(Duration.zero...outage)
                clock.schedule(.machine(.background), after: away)
                clock.schedule(.machine(.resume), after: away + random.duration(Duration.seconds(1)...(.seconds(600))))
            }
            if random.chance(0.1) { clock.schedule(.machine(.macSignaled), after: random.duration(Duration.zero...outage)) }
            clock.schedule(.networkUp, after: outage)
        case .networkUp:
            networkUp = true
            backAt = clock.now
            if pathChanged { clock.schedule(.machine(.networkChanged), after: LinkController.networkSettle) }
            // A resume or presence blip after the network is back is noise too:
            // it restarts a dial, which the bound covers as one more dial.
            slack += .seconds(2)
            // Already connected (a dial made it through the heartbeat window).
            if machine.phase.isConnected { handle(.probeFailed(generation: machine.generation, reason: "timeout")) }
        }
        if run.drops >= target, backAt == nil, networkUp, machine.phase.isConnected { break }
    }
    run.endedConnected = machine.phase.isConnected
    run.virtual = clock.now
    return run
}

/// The phase as a number, for the replay hash (a string per event would
/// cost more than the machine).
private func phaseCode(_ phase: LinkMachine.Phase) -> Int64 {
    switch phase {
    case .idle: 1
    case .macOffline: 2
    case .signedOut: 3
    case .connecting(_, let attempt): 100 + Int64(attempt)
    case .connected: 4
    case .waiting(_, let attempt, _, let retryIn): 10_000 + Int64(attempt) * 1_000 + retryIn.tickMilliseconds / 1_000
    }
}

// MARK: Deltas

/// The Mac's side of the delta cell: workspace rows and their revision.
private struct DaemonTruth {
    var revision = 1
    var names: [String]

    init(workspaces: Int) { names = (0..<workspaces).map { "ws \($0)" } }

    func row(_ index: Int) -> [String: Any] {
        ["id": index + 1, "key": "w\(index + 1)", "name": names[index], "screens": [[
            "id": index + 1, "active": true, "active_pane": index + 1,
            "panes": [["id": index + 1, "active_tab": 0, "tabs": [["surface": index + 1, "kind": "pty", "title": "t\(index)"]]]],
        ]]]
    }

    func snapshot() -> Data {
        let body: [String: Any] = ["ok": true, "data": ["workspace_revision": revision, "workspaces": names.indices.map(row)]]
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }

    /// Renames one workspace: the next revision, and its delta as the daemon writes it.
    mutating func rename(_ index: Int, to name: String) -> DaemonEvent {
        names[index] = name
        revision += 1
        let object: [String: Any] = ["event": "workspace-renamed", "workspace": index + 1, "workspace_revision": revision, "entity": row(index)]
        let line = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return DaemonEvent.parse(line)
    }
}

private enum DeltaTick {
    case emit
    case arrive(DaemonEvent)
    case snapshot
}

private struct DeltaRun {
    var applied = 0
    var stale = 0
    var resnapshots = 0
    var mismatched = 0
    /// The repair at the end: the Mac's next delta, delivered, found a gap.
    var gapAtEnd = false
    var virtual: Duration = .zero
    var faults = TickFaults.Counts()
}

/// The daemon renames workspaces `deltas` times (one every 1 ms to 2 s),
/// and the transport loses, duplicates and reorders the deltas. The phone's
/// projection applies them as they arrive: a stale one (a duplicate, or one
/// overtaken by a newer revision) changes nothing; a gap asks for a
/// snapshot, which arrives after a round trip and covers what was lost.
private func runDeltas(_ deltas: Int, workspaces: Int, seed: UInt64) async throws -> DeltaRun {
    var random = TickRandom(seed: seed)
    var clock = TickClock<DeltaTick>()
    var truth = DaemonTruth(workspaces: workspaces)
    let projection = WorkspaceProjection()
    var tree = try await projection.reset(snapshot: truth.snapshot(), macID: "m1")
    let faults = TickFaults(drop: 0.01, duplicate: 0.02, reorder: 0.02,
                            latency: Duration.milliseconds(5)...(.milliseconds(200)), lateBy: Duration.milliseconds(50)...(.seconds(3)))
    var run = DeltaRun()
    var emitted = 0
    var awaitingSnapshot = false
    // The daemon channel is one ordered stream: a delta never overtakes an
    // earlier one unless the reorder fault fires (a replay overlapping it).
    var lastArrival: Duration = .zero
    clock.schedule(.emit, at: .zero)
    while let tick = clock.next(until: .seconds(Int64(deltas) * 10)) {
        switch tick {
        case .emit:
            let index = Int(random.next() % UInt64(workspaces))
            let event = truth.rename(index, to: "ws \(index) r\(truth.revision + 1)")
            emitted += 1
            let reorderedBefore = run.faults.reordered
            if case .delivered(let delays) = faults.deliver(&random, counts: &run.faults), let first = delays.first {
                var arrival = clock.now + first
                if run.faults.reordered == reorderedBefore {
                    arrival = max(arrival, lastArrival)
                    lastArrival = arrival
                }
                clock.schedule(.arrive(event), at: arrival)
                // A duplicate's second copy comes after the first.
                for delay in delays.dropFirst() { clock.schedule(.arrive(event), at: arrival + delay - first) }
            }
            if emitted < deltas { clock.schedule(.emit, after: random.duration(Duration.milliseconds(1)...(.seconds(2)))) }
        case .arrive(let event):
            do {
                if let update = try await projection.apply(event, agents: AgentStates(), activity: [:]) {
                    tree = update.tree
                    run.applied += 1
                } else {
                    run.stale += 1
                }
            } catch {
                // A gap: re-list, as WorkspaceSync does. The reply is the Mac's
                // tree when it answers, a round trip later.
                guard !awaitingSnapshot else { break }
                awaitingSnapshot = true
                run.resnapshots += 1
                let roundTrip = random.duration(Duration.milliseconds(50)...(.milliseconds(800)))
                clock.schedule(.snapshot, after: roundTrip)
            }
        case .snapshot:
            awaitingSnapshot = false
            tree = try await projection.reset(snapshot: truth.snapshot(), macID: "m1")
        }
        if emitted >= deltas, clock.pending == 0 { break }
    }
    // A delta lost after the last one that arrived leaves no gap yet: the
    // Mac's next delta shows it. Send one more, delivered: it applies when
    // the phone is at the Mac's revision, or asks for the re-list that
    // repairs it.
    let probe = truth.rename(0, to: "ws 0 last")
    do {
        if let update = try await projection.apply(probe, agents: AgentStates(), activity: [:]) { tree = update.tree }
    } catch {
        run.gapAtEnd = true
        run.resnapshots += 1
        tree = try await projection.reset(snapshot: truth.snapshot(), macID: "m1")
    }
    let names = Dictionary(uniqueKeysWithValues: tree.workspaces.map { ($0.id, $0.title) })
    for index in truth.names.indices where names["w\(index + 1)"] != truth.names[index] { run.mismatched += 1 }
    run.virtual = clock.now
    return run
}

// MARK: Feed under memory warnings and a refusing disk

private enum FeedTick {
    case event
    case memoryWarning
    case diskFull
    case diskBack
}

// The cells run seconds of work and allocate hundreds of MB, and the kit's
// other suites share the process: LinkControllerTests waits on wall-clock
// bounds on the main actor, and FeedSpillTests measures the process's
// memory. So the suite runs only in a test run of its own
// (CMUX_TICK_HARNESS=1; scripts/ci/cmux-next-ios-sim.sh sets it when its
// only= filter names this suite), and off the main actor except for the
// Feed cell, which yields.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CMUX_TICK_HARNESS"] == "1",
                             "runs alone: CMUX_TICK_HARNESS=1"))
struct TickHarnessCellsTests {
    /// 10,000 link losses from 100 ms to 8 h, with lost, late and duplicated
    /// dial results, background/resume and presence noise. Asserts: every
    /// reconnect within its bound after the network is back (2 s with a path
    /// change, the longest backoff step and a dial without, plus what the
    /// injected faults cost); no stale result moves the machine; backoff
    /// holds (at most outage/15 + 10 dials); connected at the end; the same
    /// seed replays the same run, another seed does not.
    @Test func cellTickTenThousandReconnects() {
        let seed = TickRandom.seed(default: 40_960)
        let report = TickReport(cell: "tick_reconnects", variant: "10k", seed: seed)
        let run = runReconnects(drops: 10_000, seed: seed)
        let sorted = run.reconnects.sorted()
        let p99 = sorted.isEmpty ? Duration.zero : sorted[sorted.count * 99 / 100]
        report.finish(ops: run.drops, virtual: run.virtual, [
            "dials": run.dials, "stale_ignored": run.staleIgnored, "lost": run.faults.lost,
            "duplicated": run.faults.duplicated, "reordered": run.faults.reordered,
            "reconnect_p99_ms": Int(p99.tickSeconds * 1000), "reconnect_max_ms": Int(run.worst.tickSeconds * 1000),
        ])
        #expect(run.drops == 10_000, "seed \(seed): \(run.drops) drops")
        #expect(run.reconnects.count == run.drops, "seed \(seed): \(run.reconnects.count) reconnects for \(run.drops) drops")
        #expect(run.worstOverBound <= .zero, "seed \(seed): a reconnect took \(run.worstOverBound) past its bound")
        #expect(run.staleChangedPhase == 0, "seed \(seed): \(run.staleChangedPhase) stale results moved the machine")
        #expect(run.excessDials == 0, "seed \(seed): \(run.excessDials) outages broke the backoff")
        #expect(run.endedConnected, "seed \(seed)")
        #expect(run.staleIgnored > 0 && run.faults.lost > 0 && run.faults.duplicated > 0, "seed \(seed): the faults never fired")

        let again = runReconnects(drops: 1_000, seed: seed)
        let replay = runReconnects(drops: 1_000, seed: seed)
        let other = runReconnects(drops: 1_000, seed: seed &+ 1)
        #expect(again.trace.hash == replay.trace.hash, "seed \(seed) does not replay")
        #expect(again.trace.hash != other.trace.hash, "seeds \(seed) and \(seed &+ 1) ran the same")
    }

    /// 10,000 workspace deltas (renames with a revision each) over 200
    /// workspaces; the transport loses 1%, duplicates 2% and reorders 2%.
    /// Asserts: the phone's rows equal the Mac's at the end; every duplicate
    /// or overtaken delta changed nothing; every loss was repaired by a
    /// re-list, at most one per gap. A 2,000-delta run over 1,000
    /// workspaces reports the cost per delta at 5x the rows.
    @Test func cellTickTenThousandDeltas() async throws {
        // Off the main actor: the loop and the projection actor share no main-actor state.
        let seed = TickRandom.seed(default: 40_961)
        // The 1,000-workspace run is shorter: it is there for the cost per delta at 5x the rows.
        for (variant, workspaces, deltas) in [("200-workspaces", 200, 10_000), ("1000-workspaces", 1_000, 2_000)] {
            let report = TickReport(cell: "tick_deltas", variant: variant, seed: seed)
            let run = try await runDeltas(deltas, workspaces: workspaces, seed: seed)
            report.finish(ops: deltas, virtual: run.virtual, [
                "wall_us_per_delta": Int(report.wall.tickSeconds * 1e6) / deltas,
                "applied": run.applied, "stale": run.stale, "resnapshots": run.resnapshots,
                "lost": run.faults.lost, "duplicated": run.faults.duplicated, "reordered": run.faults.reordered,
            ])
            #expect(run.mismatched == 0, "seed \(seed) \(variant): \(run.mismatched) rows differ from the Mac's")
            #expect(run.faults.lost == 0 || run.resnapshots > 0, "seed \(seed) \(variant): a lost delta was never repaired")
            #expect(run.stale >= run.faults.duplicated, "seed \(seed) \(variant): a duplicate was applied twice")
            // A re-list per lost or overtaken delta at most: each gap costs one.
            #expect(run.resnapshots <= run.faults.lost + run.faults.reordered + 1,
                    "seed \(seed) \(variant): \(run.resnapshots) re-lists for \(run.faults.lost) lost and \(run.faults.reordered) late")
        }
    }

    /// 10,000 Feed events (1% open asks) at 50 ms to 30 s apart, with a
    /// memory warning every 2 to 20 minutes and the spill's folder refusing
    /// writes (as a full disk does) for 1 to 30 minutes now and then.
    /// Asserts after every event: at most the window (500) plus the open
    /// asks in memory, every open ask kept, no id twice; after each warning
    /// at most 100 plus the open asks. On disk: at most the spill's cap once
    /// the disk is back, and no more bytes at 10,000 events than at 5,000
    /// (past the cap the disk is flat). Scrolling to the end brings every
    /// spilled row back once.
    @MainActor @Test func cellTickFeedUnderPressureAndDiskFull() async throws {
        let seed = TickRandom.seed(default: 40_962)
        var random = TickRandom(seed: seed)
        var clock = TickClock<FeedTick>()
        let disk = try TickDisk(name: "feed-spill")
        defer { disk.remove() }
        let report = TickReport(cell: "tick_feed_pressure_disk", variant: "10k", seed: seed)
        let pressure = MemoryPressure(observesSystem: false)
        let store = FeedStore(items: [], memoryPressure: pressure)
        let spill = RowSpill<FeedItem>(directory: disk.directory.appending(path: "feed", directoryHint: .isDirectory), pageSize: 100, maxRows: 2_000)
        store.useSpill(spill)
        let spillDisk = try TickDisk(directory: spill.directory)
        defer { spillDisk.allow() }

        let events = 10_000
        // The last refusal ends well before the end, so the cap is checked after a write.
        let lastRefusal = Duration.seconds(Int64(events) * 15 * 8 / 10)
        var emitted = 0
        var openAsks: Set<String> = []
        var warnings = 0, refusals = 0, refusedWrites = 0
        var overWindow = 0, overPressure = 0, lostAsks = 0, duplicateIDs = 0
        var refusing = false
        var midBytes = 0
        clock.schedule(.event, at: .zero)
        clock.schedule(.memoryWarning, after: random.duration(Duration.seconds(120)...(.seconds(1200))))
        clock.schedule(.diskFull, after: random.duration(Duration.seconds(600)...(.seconds(3600))))
        while let tick = clock.next(until: .seconds(Int64(events) * 60)) {
            switch tick {
            case .event:
                // FeedStore is main-actor state: give other main-actor work a turn.
                if emitted % 50 == 0 { await Task.yield() }
                let ask = random.chance(0.01)
                let id = "e\(emitted)"
                store.upsert(FeedItem(id: id, kind: ask ? .needsInput : .finished, workspaceID: "w\(emitted % 40)", tabID: "t",
                                      agentName: "Codex", harness: "codex", workspaceTitle: "cmux",
                                      markdown: "event \(emitted)", quote: nil,
                                      createdAt: Date(timeIntervalSince1970: 1_000_000 + clock.now.tickSeconds)), atTop: true)
                if ask { openAsks.insert(id) }
                emitted += 1
                if refusing { refusedWrites += 1 }
                if store.items.count > FeedStore.memoryLimit + openAsks.count { overWindow += 1 }
                if emitted % 500 == 0 {
                    let ids = Set(store.items.map(\.id))
                    if ids.count != store.items.count { duplicateIDs += 1 }
                    lostAsks += openAsks.subtracting(ids).count
                }
                if emitted >= events / 2, midBytes == 0, !refusing {
                    spill.flush()
                    midBytes = disk.bytes()
                }
                if emitted < events { clock.schedule(.event, after: random.duration(Duration.milliseconds(50)...(.seconds(30)))) }
            case .memoryWarning:
                warnings += 1
                pressure.relieve()
                if store.items.count > FeedStore.pressureLimit + openAsks.count { overPressure += 1 }
                clock.schedule(.memoryWarning, after: random.duration(Duration.seconds(120)...(.seconds(1200))))
            case .diskFull:
                guard clock.now < lastRefusal else { break }
                spill.flush()
                #expect(spillDisk.refuse(), "the injected disk-full did not refuse a write (running as root?)")
                refusing = true
                refusals += 1
                clock.schedule(.diskBack, after: random.duration(Duration.seconds(60)...(.seconds(1800))))
            case .diskBack:
                spill.flush()
                spillDisk.allow()
                refusing = false
                clock.schedule(.diskFull, after: random.duration(Duration.seconds(600)...(.seconds(3600))))
            }
            if emitted >= events, !refusing { break }
        }
        spill.flush()
        let stored = spill.storedCount()
        let endBytes = disk.bytes()
        // The person scrolls to the end until the spill is empty: a page per scroll.
        let before = store.items.count
        var scrolls = 0
        while store.olderOnDisk > 0, scrolls < 1_000 {
            await store.loadOlderPage()
            scrolls += 1
        }
        let ids = store.items.map(\.id)
        report.finish(ops: emitted, virtual: clock.now, [
            "warnings": warnings, "disk_refusals": refusals, "events_while_refused": refusedWrites,
            "spill_rows": stored, "disk_bytes_mid": midBytes, "disk_bytes_end": endBytes,
            "items_after_reload": ids.count, "scrolls": scrolls, "open_asks": openAsks.count,
        ])
        #expect(emitted == events)
        #expect(warnings > 10 && refusals > 2, "seed \(seed): \(warnings) warnings, \(refusals) disk refusals")
        #expect(overWindow == 0, "seed \(seed): \(overWindow) events left more than the window in memory")
        #expect(overPressure == 0, "seed \(seed): \(overPressure) warnings left more than \(FeedStore.pressureLimit) events")
        #expect(lostAsks == 0, "seed \(seed): \(lostAsks) open asks left memory")
        #expect(duplicateIDs == 0, "seed \(seed): an event was held twice")
        // `storedCount` includes the rows short of a page the spill holds in memory.
        #expect(stored <= spill.maxRows + spill.pageSize - 1, "seed \(seed): \(stored) rows spilled, cap \(spill.maxRows) plus a page")
        #expect(midBytes > 0 && Double(endBytes) <= Double(midBytes) * 1.2, "seed \(seed): disk grew past the cap, \(midBytes) to \(endBytes) bytes")
        #expect(Set(ids).count == ids.count, "seed \(seed): reading back the spill duplicated an event")
        // Every row the spill held (pages and the rows short of a page) came back once.
        #expect(ids.count - before == stored, "seed \(seed): \(ids.count - before) rows came back of \(stored) spilled")
    }
}
