import Foundation
import Testing
@testable import CmuxNextDaemon

/// Two views of one terminal on the real daemon (plans/cmux-next/sync-ux/DESIGN.md 2.4 and 2.6):
/// a Mac view and a phone-kind view, each naming its device in `set-client-info`. Under the
/// default policy (last active) the phone's attach does not take the grid, the view that does not
/// set the grid learns who does ("Sized for <device>"), and a claim (focus, Take over) moves the
/// grid and the notice.
@Suite(.enabled(if: RealBinary.isBranchBuild, "needs the same-tree cmux-tui (scripts/cmux-next/pin-cmux-tui.sh fetch)"),
       .timeLimit(.minutes(2)), .liveDaemon)
struct BranchSizedForTests {
    @Test func theViewThatDoesNotSetTheGridIsToldWhoDoes() async throws {
        try await BranchDaemonHarness.with { h in
            let (_, _, surface) = try await h.workspaceWithTerminal("sized-for")
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
            let glance = await Self.notice(in: &phoneEvents) { $0 != nil }
            #expect(glance == TerminalSizeNotice(ownerName: "Studio", ownerKind: "mac", sameDevice: false,
                                                 cols: 100, rows: 30, mode: "latest"),
                    "the phone's attach took the grid or the phone was not told: \(String(describing: glance))")

            // The phone takes over: the grid is the phone's, the Mac is told, the phone's notice clears.
            phone.claimGeometry(reporting: CellSize(cols: 50, rows: 20))
            let macTold = await Self.notice(in: &macEvents) { $0 != nil }
            #expect(macTold == TerminalSizeNotice(ownerName: "Pocket", ownerKind: "iphone", sameDevice: false,
                                                  cols: 50, rows: 20, mode: "latest"),
                    "the Mac was not told the phone sets the grid: \(String(describing: macTold))")
            let phoneCleared = await Self.notice(in: &phoneEvents) { $0 == nil }
            #expect(phoneCleared == nil)

            // The Mac takes it back (a focus click or Take over is this claim): its notice clears.
            mac.claimGeometry(reporting: CellSize(cols: 100, rows: 30))
            let macCleared = await Self.notice(in: &macEvents) { $0 == nil }
            #expect(macCleared == nil)
        }
    }

    /// The first size state whose notice matches `wanted`; `.some(nil)` is a cleared notice.
    /// Returns the matched notice, or a sentinel notice naming the end of the stream.
    private static func notice(
        in events: inout AsyncStream<TerminalChannelEvent>.Iterator,
        where wanted: (TerminalSizeNotice?) -> Bool
    ) async -> TerminalSizeNotice? {
        while let event = await events.next() {
            switch event {
            case .sizeState(let state, let participant):
                let notice = state.notice(for: participant)
                if wanted(notice) { return notice }
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
