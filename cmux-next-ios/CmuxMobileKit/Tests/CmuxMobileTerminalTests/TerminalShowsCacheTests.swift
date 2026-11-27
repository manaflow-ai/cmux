#if os(iOS)
import CmuxMobileArtifacts
import CmuxMobileDesign
import Foundation
import Testing
import UIKit
@testable import CmuxMobileTerminal

/// Leo, 2026-11-12, on LTE: "wack reconnection state / just show the cache".
@MainActor
@Suite struct TerminalShowsCacheTests {
    @MainActor
    final class Silent: TerminalSession {
        let programName = "zsh"
        let isAlternateScreen = false
        var connectionState: TerminalConnectionState = .connecting(mac: "Mac Studio")
        func start(_ handler: @escaping @MainActor (TerminalSessionEvent) -> Void) {}
        func send(_ bytes: Data) {}
        func resize(columns: Int, rows: Int) {}
        func stop() {}
    }

    static func frame() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { _ in }
    }

    private func makeModel(delay: Duration = QuietStatusGate.threshold) -> TerminalModel {
        TerminalModel(session: Silent(), artifactSource: UnavailableArtifactSource(), title: "interim-coord",
                      quietStatus: QuietStatusGate(delay: delay))
    }

    /// A cached frame wins over the skeleton in every state; the skeleton is
    /// only for a terminal never opened on this phone.
    @Test func theCachedFrameNeverGivesWayToTheSkeleton() {
        #expect(TerminalConnectingView.content(hasLastFrame: true, showsPlaceholder: true) == .lastFrame)
        #expect(TerminalConnectingView.content(hasLastFrame: true, showsPlaceholder: false) == .lastFrame)
        #expect(TerminalConnectingView.content(hasLastFrame: false, showsPlaceholder: true) == .skeleton)
        #expect(TerminalConnectingView.content(hasLastFrame: false, showsPlaceholder: false) == .nothing)
        // The Mac's pushed screen text stands in for the skeleton, never over a frame or live rows.
        #expect(TerminalConnectingView.content(hasLastFrame: false, showsPlaceholder: true, hasScreenText: true) == .screenText)
        #expect(TerminalConnectingView.content(hasLastFrame: true, showsPlaceholder: true, hasScreenText: true) == .lastFrame)
        #expect(TerminalConnectingView.content(hasLastFrame: false, showsPlaceholder: false, hasScreenText: true) == .nothing)
    }

    /// The link's own line (a network that blocks it) is the stalled panel's reason, over the
    /// generic words; "Offline" alone adds nothing to the title.
    @Test func theStalledPanelPrefersTheLinksOwnLine() {
        #expect(TerminalLoadStalledPanel.notice(.offline(mac: "Mac Studio"), linkStatus: "This network blocks the connection")?.detail
            == "This network blocks the connection")
        #expect(TerminalLoadStalledPanel.notice(.offline(mac: "Mac Studio"), linkStatus: "Offline")?.detail
            == "The terminal opens when it is back.")
        #expect(TerminalLoadStalledPanel.notice(.failed(message: "x"), linkStatus: "Blocked")?.detail == "Blocked")
        #expect(TerminalLoadStalledPanel.notice(.reattaching(mac: "Mac Studio"), linkStatus: "Blocked") == nil)
    }

    /// The offline subtitle says how old the saved copy is, and only when the page shows one.
    @Test func theOfflineLineSaysHowOldTheSavedCopyIs() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let model = makeModel()
        #expect(model.savedCopyAgePhrase(since: now.addingTimeInterval(-20), now: now) == "updated just now")
        #expect(model.savedCopyAgePhrase(since: now.addingTimeInterval(-185), now: now) == "updated 3 min ago")
        #expect(model.savedCopyAgePhrase(since: now.addingTimeInterval(-7300), now: now) == "updated 2 h ago")
        #expect(model.offlineSubtitle(nil) == nil)
        // Nothing of the Mac's on the page: no age to tell.
        model.restoreSavedAt(now.addingTimeInterval(-185))
        #expect(model.offlineSubtitle("Mac offline", now: now) == "Mac offline")
        model.restoreLastFrame(Self.frame())
        #expect(model.offlineSubtitle("Mac offline", now: now) == "Mac offline · updated 3 min ago")
        // An older date never replaces a newer one.
        model.restoreSavedAt(now.addingTimeInterval(-9000))
        #expect(model.offlineSubtitle("Mac offline", now: now) == "Mac offline · updated 3 min ago")
    }

    /// A page with nothing of its own takes a saved copy that arrives late; one that is attached
    /// or already shows rows never does.
    @Test func onlyABlankDetachedPageTakesALateSeed() {
        let model = makeModel()
        #expect(model.takesLateSeed)
        model.cardScreenText = "$ ls\nREADME.md"
        #expect(model.takeSeed() != nil)
        #expect(!model.takesLateSeed)
        let attached = makeModel()
        attached.ingest(.connection(.attached))
        #expect(!attached.takesLateSeed)
    }

    /// A cover with no kept frame ends at the composer's top, never under the composer bar
    /// (iOS regression row 20, Aziz 2026-11-26: "the loading terminal placeholder shouldnt leak
    /// under the composer bar").
    @Test func theCoverEndsAtTheComposersTop() {
        #expect(TerminalConnectingView.coverBottom(height: 800, rowsLift: 120) == 680)
        #expect(TerminalConnectingView.coverBottom(height: 800, rowsLift: nil) == 800)
        #expect(TerminalConnectingView.coverBottom(height: 800, rowsLift: -5) == 800)
        #expect(TerminalConnectingView.coverBottom(height: 100, rowsLift: 300) == 0)
    }

    /// Connection changes keep the cached frame (only drawn live rows replace it).
    @Test func connectionChangesKeepTheCachedFrame() {
        let model = makeModel()
        let frame = Self.frame()
        model.restoreLastFrame(frame)
        for state in [TerminalConnectionState.connecting(mac: "Mac Studio"), .failed(message: "x"), .reattaching(mac: "Mac Studio"),
                      .offline(mac: "Mac Studio"), .connecting(mac: "Mac Studio")] {
            model.ingest(.connection(state))
            #expect(model.coldFrame === frame, "\(state) dropped the cached frame")
        }
    }

    @Test func theQuietLineWaitsForTheThreshold() async throws {
        let quiet = makeModel()
        quiet.ingest(.connection(.reattaching(mac: "Mac Studio")))
        #expect(quiet.connectionLine == nil, "nothing for the first 10 s")

        let model = makeModel(delay: .milliseconds(60))
        model.ingest(.connection(.attached))
        model.ingest(.connection(.reattaching(mac: "Mac Studio")))
        #expect(model.connectionLine == nil)
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.connectionLine == nil, "a reattach says nothing, however long (Leo 2026-11-22)")
        // Retries keep the first instant; a failure after them reads plainly.
        model.ingest(.connection(.failed(message: "daemon channel closed")))
        #expect(model.connectionLine == "Can't reach this terminal")
        model.ingest(.connection(.attached))
        #expect(model.connectionLine == nil)
    }

    @Test func quietLinesNeverCarryTransportWords() {
        for state in [TerminalConnectionState.offline(mac: nil), .failed(message: "daemon channel closed")] {
            let line = state.quietLine ?? ""
            #expect(!line.isEmpty)
            #expect(!line.contains("daemon") && !line.contains("channel"), "\(line)")
        }
        #expect(TerminalConnectionState.attached.quietLine == nil)
        #expect(TerminalConnectionState.connecting(mac: nil).quietLine == nil)
        #expect(TerminalConnectionState.reattaching(mac: "Mac Studio").quietLine == nil)
    }
}
#endif
