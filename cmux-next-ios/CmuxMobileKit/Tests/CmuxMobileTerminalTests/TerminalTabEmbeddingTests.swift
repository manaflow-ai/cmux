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
        let model = TerminalModel(session: ComposerHeldSendTests.StubSession(),
                                  artifactSource: MockArtifactSource(), title: "pending")
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
        secondWindow.rootViewController = UIHostingController(rootView: TerminalTabPage(host: host, insets: insets, isInteractive: true))
        secondWindow.makeKeyAndVisible()
        try await TerminalPredictionInputTests.waitUntil(5) { terminal.view.window === secondWindow }
        try #require(terminal.view.window === secondWindow)

        // The incoming page is already mounted when the old representable
        // disappears. Keep its hosting controller alive through that update.
        outgoing.rootView = AnyView(EmptyView())
        try await Task.sleep(for: .milliseconds(500)) // test: SwiftUI completes the outgoing teardown
        firstWindow.isHidden = true
        firstWindow.rootViewController = nil
        secondWindow.layoutIfNeeded()
        #expect(terminal.view.window === secondWindow)
        #expect(terminal.view.isDescendant(of: secondWindow))
        #expect(terminal.view.bounds.height > 0)
        #expect(model.composerText == "keep this draft")
        let field = try #require(findComposer(in: terminal.view))
        let frame = field.convert(field.bounds, to: secondWindow)
        #expect(frame.height > 0)
        #expect(frame.minY > secondWindow.bounds.midY, "the pending composer rests above the bottom toolbar: \(frame)")
        #expect(frame.maxY <= secondWindow.bounds.maxY - insets.bottom + 8)
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
