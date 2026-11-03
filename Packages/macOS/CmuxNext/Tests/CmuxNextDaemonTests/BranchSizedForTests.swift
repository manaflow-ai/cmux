import Foundation
import Testing
@testable import CmuxNextDaemon

/// Two views of one terminal on the real daemon (plans/cmux-next/sync-ux/DESIGN.md 2.4 and 2.6):
/// a Mac view and a phone-kind view, each naming its device in `set-client-info`. Under last active
/// (pinned on the terminal: a cmux-next daemon that reads its settings file defaults to Fit the
/// smallest viewer, host-size-policy-v1, PR #24650) the phone's attach does not take the grid, the view that does not
/// set the grid learns who does ("Sized for <device>"), and a claim (focus, Take over) moves the
/// grid and the notice. Under a policy that picks by size, the Mac's Take over sets the terminal to
/// last active and takes the grid back.
@Suite(.enabled(if: RealBinary.isBranchBuild, "needs the same-tree cmux-tui (scripts/cmux-next/pin-cmux-tui.sh fetch)"),
       .timeLimit(.minutes(2)), .liveDaemon)
struct BranchSizedForTests {
    @Test func theViewThatDoesNotSetTheGridIsToldWhoDoes() async throws {
        try await BranchDaemonHarness.with { h in
            let (_, _, surface) = try await h.workspaceWithTerminal("sized-for")
            // The host default is `smallest` (bb425d70ed3), where the phone's attach takes the grid by
            // design; this test is about last active, so the terminal pins it, as sized_attach.rs does.
            _ = try await h.connection.request(SetSizePolicyRequest(surface: surface, policy: .init(mode: "latest")))
            let target = TerminalAttachment.Target(surface: surface, generation: h.identity.generation)
            let mac = try await TerminalAttachment.attach(
                endpoint: h.endpoint, target: target, size: CellSize(cols: 100, rows: 30), claimGeometry: true,
                device: TerminalSizingDevice(kind: "mac", name: "Studio"))
            let phone = try await TerminalAttachment.attach(
                endpoint: h.endpoint, target: target, size: CellSize(cols: 50, rows: 20), claimGeometry: false,
                device: TerminalSizingDevice(kind: "iphone", name: "Pocket"))
            let watchdog = Task {
                try await Task.sleep(for: .seconds(30))
                mac.detachNow()
                phone.detachNow()
            }
            defer {
                watchdog.cancel()
                mac.detachNow()
                phone.detachNow()
            }
            var macEvents = mac.events.makeAsyncIterator()
            var phoneEvents = phone.events.makeAsyncIterator()

            // The phone only attached: the Mac keeps the grid, and the phone is told.
            let glance = await Self.notice(in: &phoneEvents) { notice, _ in notice != nil }
            #expect(glance == TerminalSizeNotice(ownerName: "Studio", ownerKind: "mac", sameDevice: false,
                                                 cols: 100, rows: 30, mode: "latest", reason: "latest"),
                    "the phone's attach took the grid or the phone was not told: \(String(describing: glance))")

            #expect(glance?.takeOverSetsLatest == false, "under last active a claim alone moves the grid")

            // The phone takes over: the grid is the phone's, the Mac is told, the phone's notice clears.
            phone.takeOver(reporting: CellSize(cols: 50, rows: 20), setLatest: false)
            let macTold = await Self.notice(in: &macEvents) { notice, _ in notice != nil }
            #expect(macTold == TerminalSizeNotice(ownerName: "Pocket", ownerKind: "iphone", sameDevice: false,
                                                  cols: 50, rows: 20, mode: "latest", reason: "latest"),
                    "the Mac was not told the phone sets the grid: \(String(describing: macTold))")
            let phoneCleared = await Self.notice(in: &phoneEvents) { notice, _ in notice == nil }
            #expect(phoneCleared == nil)

            // The Mac takes it back (a focus click or Take over is this claim): its notice clears.
            mac.claimGeometry(reporting: CellSize(cols: 100, rows: 30))
            let macCleared = await Self.notice(in: &macEvents) { notice, _ in notice == nil }
            #expect(macCleared == nil)

            // Fit everyone: the phone's smaller screen sets the grid, and no claim can move it.
            _ = try await h.connection.request(SetSizePolicyRequest(surface: surface, policy: .init(mode: "smallest")))
            let fitted = await Self.notice(in: &macEvents) { notice, _ in notice?.mode == "smallest" }
            #expect(fitted?.ownerName == "Pocket" && fitted?.cols == 50,
                    "smallest did not give the phone the grid: \(String(describing: fitted))")
            #expect(fitted?.takeOverSetsLatest == true, "Take over under smallest must set last active first")
            let phoneOwns = await Self.notice(in: &phoneEvents) { notice, state in
                notice == nil && state.policy?.mode == "smallest"
            }
            #expect(phoneOwns == nil)

            // The Mac's Take over: the terminal becomes last active and the Mac sets the grid again.
            mac.takeOver(reporting: CellSize(cols: 100, rows: 30), setLatest: true)
            let tookOver = await Self.notice(in: &macEvents) { notice, state in
                notice == nil && state.policy?.mode == "latest"
            }
            #expect(tookOver == nil)
            let phoneToldAgain = await Self.notice(in: &phoneEvents) { notice, state in
                notice?.ownerName == "Studio" && state.policy?.mode == "latest"
            }
            #expect(phoneToldAgain?.cols == 100,
                    "the Mac's Take over did not set last active and take the grid: \(String(describing: phoneToldAgain))")
        }
    }

    /// The first size state whose notice (and state) matches `wanted`; `.some(nil)` is a cleared
    /// notice. Returns the matched notice, or a sentinel notice naming the end of the stream.
    /// `@concurrent`, like `AsyncStream.Iterator.next()`: the caller sends its iterator here once,
    /// and the reads do not hop isolation again (the target's default isolation is the main actor).
    @concurrent private nonisolated static func notice(
        in events: inout AsyncStream<TerminalChannelEvent>.Iterator,
        where wanted: (TerminalSizeNotice?, TerminalSizeState) -> Bool
    ) async -> TerminalSizeNotice? {
        while let event = await events.next() {
            switch event {
            case .sizeState(let state, let participant):
                let notice = state.notice(for: participant)
                if wanted(notice, state) { return notice }
            case .closed(let reason):
                return TerminalSizeNotice(ownerName: "stream closed: \(reason)", ownerKind: nil, sameDevice: false,
                                          cols: 0, rows: 0, mode: nil)
            default:
                continue
            }
        }
        return TerminalSizeNotice(ownerName: "stream ended", ownerKind: nil, sameDevice: false, cols: 0, rows: 0, mode: nil)
    }
}
