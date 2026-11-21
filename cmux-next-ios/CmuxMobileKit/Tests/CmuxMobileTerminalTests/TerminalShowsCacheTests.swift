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
        for _ in 0..<200 where model.connectionLine == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.connectionLine == "Reconnecting to Mac Studio…")
        // Retries keep the first instant; a failure after them reads plainly.
        model.ingest(.connection(.failed(message: "daemon channel closed")))
        #expect(model.connectionLine == "Can't reach this terminal")
        model.ingest(.connection(.attached))
        #expect(model.connectionLine == nil)
    }

    @Test func quietLinesNeverCarryTransportWords() {
        for state in [TerminalConnectionState.connecting(mac: nil), .reattaching(mac: "Mac Studio"), .offline(mac: nil),
                      .failed(message: "daemon channel closed")] {
            let line = state.quietLine ?? ""
            #expect(!line.isEmpty)
            #expect(!line.contains("daemon") && !line.contains("channel"), "\(line)")
        }
        #expect(TerminalConnectionState.attached.quietLine == nil)
    }
}
#endif
