#if os(iOS)
@testable import CmuxMobileDesign
import SwiftUI
import Testing
import UIKit

/// Detector: a connection indicator never shifts layout (Leo, 2026-11-21: "these messages should
/// not be pushing up the text ... a symbol or short thing, not a sentence. stop layout shifting").
///
/// Mounts a list of rows under `cmuxMobileBanner` (the Workspaces list and Home) in a phone-sized
/// window in each link state (connected, reconnecting, offline, Mac offline, failed) and in the
/// states that carry a sentence or an action (signed out, pairing, a failed refresh), then reads
/// every row's frame. Any row that moved from the connected frame fails the test with its points
/// of shift: a banner put back in a `safeAreaInset` or a stack fails here. A link state must also
/// draw as a chip (at most half the width), not a sentence.
@MainActor @Suite(.serialized) struct ConnectionStateLayoutShiftTests {
    static let rows = 12

    static let states: [(String, ConnectionBannerState?)] = [
        ("connected", nil),
        ("reconnecting", .reconnecting(to: "Mac Studio")),
        ("connecting", .connecting(to: "Mac Studio")),
        ("offline", .offline),
        ("mac offline", .macOffline("Mac Studio")),
        ("connection failed", .connectionFailed),
        ("signed out", .signedOut),
        ("pairing", .waitingForPairing(on: "Mac Studio")),
        ("refresh failed", .refreshFailed()),
    ]

    /// Row frames, by index, reported by each row as it lays out.
    @MainActor final class Frames {
        var rows: [Int: CGRect] = [:]
        /// The indicator's own frame, when one shows.
        var indicator: CGRect?
    }

    struct Page: View {
        let state: ConnectionBannerState?
        let frames: Frames
        /// Draws the banner the way feat-cmux-next did before this check (a top safe-area
        /// inset, 8 pt above and below): the before number, and proof the check catches it.
        var legacy = false

        // As the Workspaces list (Screens.swift) and Home use it: the banner on the screen's
        // content inside its NavigationStack, under the navigation bar.
        var body: some View {
            NavigationStack {
                placed
                    .navigationTitle("Workspaces")
                    .navigationBarTitleDisplayMode(.inline)
            }
        }

        @ViewBuilder private var placed: some View {
            if legacy {
                rows.safeAreaInset(edge: .top, spacing: 0) {
                    if let state {
                        ConnectionBanner(state, retry: {}).padding(.vertical, 8).frame(maxWidth: .infinity)
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frames.indicator = $0 }
                    }
                }
            } else {
                rows.cmuxMobileBanner(state, retry: {})
            }
        }

        private var rows: some View {
            ScrollView {
                VStack(spacing: 0) {
                    // test: a fixed page of rows.
                    ForEach(0 ..< ConnectionStateLayoutShiftTests.rows, id: \.self) { index in
                        Text(verbatim: "Workspace \(index)")
                            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frames.rows[index] = $0 }
                    }
                }
            }
        }
    }

    @MainActor final class Harness {
        let window: UIWindow
        let host = UIHostingController(rootView: AnyView(EmptyView()))
        init() {
            // In the test host's window scene when it has one: a window with no scene gets no
            // safe-area pass, so an inset banner read as moving nothing.
            let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
            window.frame = CGRect(x: 0, y: 0, width: 402, height: 874) // iPhone 17 Pro
            window.rootViewController = host
            window.makeKeyAndVisible()
        }

        /// Lays `state`'s page out for a few display frames (its enter transition included) and
        /// returns the rows' frames.
        func measure(_ state: ConnectionBannerState?, legacy: Bool = false) async -> Frames {
            let frames = Frames()
            // A fresh mount each time (a new identity), so every row reports its frame into this
            // `Frames` rather than keeping the one it laid out in the last state.
            host.rootView = AnyView(Page(state: state, frames: frames, legacy: legacy).id(UUID()))
            for _ in 0 ..< 30 {
                try? await Task.sleep(for: .milliseconds(16)) // test: one display frame of layout
                host.view.layoutIfNeeded()
            }
            return frames
        }
    }

    /// Points each row moved from where it sits with no indicator; 0 everywhere is the rule.
    /// A row with no frame in either reading is unmeasured, never 0: it reads as infinity.
    static func shift(_ frames: Frames, from base: Frames) -> CGFloat {
        guard !base.rows.isEmpty, frames.rows.count == base.rows.count else { return .infinity }
        return base.rows.reduce(0) { worst, entry in
            guard let moved = frames.rows[entry.key] else { return .infinity }
            return max(worst, abs(moved.minY - entry.value.minY), abs(moved.height - entry.value.height))
        }
    }

    @Test func noConnectionStateMovesTheRows() async {
        let harness = Harness()
        let base = await harness.measure(nil)
        #expect(base.rows.count >= 6, "rows laid out: \(base.rows.count)")
        var report: [String] = []
        for (name, state) in Self.states.dropFirst() {
            let shown = await harness.measure(state)
            let points = Self.shift(shown, from: base)
            report.append("\(name): \(points) pt (\(shown.rows.count)/\(base.rows.count) rows; row 0 y \(base.rows[0]?.minY ?? -1) -> \(shown.rows[0]?.minY ?? -1); indicator \(shown.indicator.map { "\($0.height) pt high at y \($0.minY)" } ?? "unmeasured"); window scene \(harness.window.windowScene != nil))")
            #expect(points == 0, "\(name): the rows moved \(points) pt when it showed")
            // And back: the rows return to the same frames when it leaves.
            let back = await harness.measure(nil)
            #expect(Self.shift(back, from: base) == 0, "\(name): the rows moved when it left")
        }
        print("ConnectionStateLayoutShift after: " + report.joined(separator: ", "))
        Attachment.record(report.joined(separator: "\n"), named: "layout-shift-after.txt") // the step exports it
    }

    /// The check catches the placement it replaced: a banner in a top safe-area inset pushes
    /// the rows down by its height. Prints the before numbers from the same harness.
    @Test func theOldInsetPlacementFails() async {
        let harness = Harness()
        let base = await harness.measure(nil, legacy: true)
        var report: [String] = []
        for (name, state) in Self.states.dropFirst() {
            let shown = await harness.measure(state, legacy: true)
            let points = Self.shift(shown, from: base)
            report.append("\(name): \(points) pt (\(shown.rows.count)/\(base.rows.count) rows; row 0 y \(base.rows[0]?.minY ?? -1) -> \(shown.rows[0]?.minY ?? -1); indicator \(shown.indicator.map { "\($0.height) pt high at y \($0.minY)" } ?? "unmeasured"); window scene \(harness.window.windowScene != nil))")
            #expect(points > 0 && points.isFinite, "\(name): the inset banner moved nothing, so the check would miss it")
        }
        print("ConnectionStateLayoutShift before: " + report.joined(separator: ", "))
        Attachment.record(report.joined(separator: "\n"), named: "layout-shift-before.txt") // the step exports it
    }

    /// A link state is a chip a few words wide, never a sentence across the screen.
    @Test func aLinkStateIsAChipNotASentence() {
        let links: [ConnectionBannerState] = [.reconnecting(to: "Mac Studio"), .connecting(to: "Mac Studio"), .offline,
                                              .macOffline("Mac Studio"), .connectionFailed]
        for state in links {
            guard let chip = state.chip else {
                Issue.record("\(state.text): drawn as a banner, not a chip")
                continue
            }
            #expect(chip.word.split(separator: " ").count <= 2, "\(chip.word): more than two words")
            #expect(!chip.word.hasSuffix(".") && !chip.word.hasSuffix("…"), "\(chip.word): a sentence")
            let host = UIHostingController(rootView: ConnectionChip(chip, retry: {}))
            let size = host.sizeThatFits(in: CGSize(width: 402, height: 200))
            #expect(size.width <= 201, "\(chip.word): \(size.width) pt wide, over half the phone")
        }
    }
}
#endif
