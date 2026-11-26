#if os(iOS) && DEBUG
import CmuxMobileArtifacts
import SwiftUI
import Testing
import UIKit
@testable import CmuxMobileTerminal

/// A retained tab can move to its new page before SwiftUI tears down the old
/// page. That teardown must not detach its terminal or its pending composer.
@MainActor
@Suite(.serialized) struct TerminalTabEmbeddingTests {
    @Test func outgoingPageTeardownKeepsTheTerminalInItsIncomingPage() async throws {
        await TerminalScreenTestLock.acquire()
        defer { TerminalScreenTestLock.release() }
        let session = ClaimRecordingSession()
        let model = TerminalModel(session: session, artifactSource: MockArtifactSource(), title: "pending")
        model.ingest(.connection(.connecting(mac: "Demo Mac")))
        model.composerText = "keep this draft"
        let host = TerminalTabHost(model: model)
        let insets = EdgeInsets(top: 62, leading: 0, bottom: 90, trailing: 0)
        let outgoing = UIHostingController(rootView: AnyView(TerminalTabPage(host: host, insets: insets, isInteractive: true)))
        let firstWindow = UIWindow(frame: UIScreen.main.bounds)
        firstWindow.rootViewController = outgoing
        firstWindow.makeKeyAndVisible()
        let terminal = host.controller
        let secondWindow = UIWindow(frame: UIScreen.main.bounds)
        defer {
            firstWindow.isHidden = true
            firstWindow.rootViewController = nil
            secondWindow.isHidden = true
            secondWindow.rootViewController = nil
        }
        try await TerminalPredictionInputTests.waitUntil(5) { terminal.view.window === firstWindow }
        try #require(terminal.view.window === firstWindow)
        let incoming = UIHostingController(rootView: AnyView(TerminalTabPage(host: host, insets: insets, isInteractive: true)))
        secondWindow.rootViewController = incoming
        secondWindow.makeKeyAndVisible()
        try await TerminalPredictionInputTests.waitUntil(5) { terminal.view.window === secondWindow }
        try #require(terminal.view.window === secondWindow)

        // The incoming page is already mounted when the old representable
        // disappears. Keep its hosting controller alive through that update.
        outgoing.rootView = AnyView(EmptyView())
        // test: SwiftUI completes the outgoing teardown, then the size claim's release debounce
        // (1 s) runs out: a stale outgoing page's `onDisappear` must not have started it.
        try await Task.sleep(for: .milliseconds(1500))
        firstWindow.isHidden = true
        firstWindow.rootViewController = nil
        secondWindow.layoutIfNeeded()
        #expect(session.claims.isEmpty, "the visible page keeps the terminal's size claim; none was released: \(session.claims)")
        #expect(terminal.view.window === secondWindow)
        #expect(terminal.view.isDescendant(of: secondWindow))
        #expect(terminal.view.bounds.height > 0)
        #expect(model.composerText == "keep this draft")
        let field = try #require(findComposer(in: terminal.view))
        let frame = field.convert(field.bounds, to: secondWindow)
        #expect(frame.height > 0)
        #expect(frame.minY > secondWindow.bounds.midY, "the pending composer rests above the bottom toolbar: \(frame)")
        #expect(frame.maxY <= secondWindow.bounds.maxY - insets.bottom + 8)

        // The final owner leaving still releases the claim once the debounce runs out, so the
        // recording above saw a working session, not a silent one.
        incoming.rootView = AnyView(EmptyView())
        try await Task.sleep(for: .milliseconds(1500)) // test: the release debounce (1 s) runs out
        #expect(session.claims == [false], "the last page's departure releases the claim: \(session.claims)")
    }

    /// A session that keeps what the size claimer told it, in order.
    @MainActor
    final class ClaimRecordingSession: TerminalSession {
        let programName = "zsh"
        let isAlternateScreen = false
        private(set) var claims: [Bool] = []
        func start(_ handler: @escaping @MainActor (TerminalSessionEvent) -> Void) {}
        func send(_ bytes: Data) {}
        func resize(columns: Int, rows: Int) {}
        func stop() {}
        func setClaimsSize(_ claims: Bool) { self.claims.append(claims) }
    }

    private func findComposer(in view: UIView) -> UIView? {
        if view.accessibilityIdentifier == "terminal.composer.field" { return view }
        for child in view.subviews {
            if let field = findComposer(in: child) { return field }
        }
        return nil
    }
}
#endif
