#if os(iOS) && DEBUG
import CmuxMobileArtifacts
import Foundation
import Testing
import UIKit
@testable import CmuxMobileTerminal

/// Follow-up to #41930 ("just show the cache"): a page shows its cached frame
/// until the Mac's terminal is attached and placed. An attach to an empty
/// terminal sends only the mirror reset (no bytes after it); the cached frame
/// must still go then, never cover the live surface for good.
@MainActor
@Suite(.serialized) struct TerminalColdFrameHandoffTests {
    @Test func aResetOnlyAttachDropsTheCachedFrame() async throws {
        await TerminalScreenTestLock.acquire()
        defer { TerminalScreenTestLock.release() }
        let session = TerminalPredictionInputTests.EchoSession()
        session.echoes = false
        session.connectionState = .reattaching(mac: nil)
        let model = TerminalModel(session: session, artifactSource: MockArtifactSource(), title: "cold")
        let screen = TerminalViewController(model: model)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = screen
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        try await TerminalPredictionInputTests.waitUntil(5) { session.handler != nil }
        try #require(session.handler != nil, "the screen never started its session")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { _ in }
        model.restoreLastFrame(image)
        #expect(model.coldFrame != nil)

        session.connection(.attached)
        session.write(TerminalViewController.mirrorReset)
        // The replay gate's deadline (2 s) is the latest the frame may stay.
        try await TerminalPredictionInputTests.waitUntil(TerminalReplayGate.deadline + 2) { model.coldFrame == nil }
        #expect(model.coldFrame == nil, "the cached frame still covers the attached, empty terminal")
    }

    @Test func aFailedAttachKeepsTheCachedFrame() async throws {
        await TerminalScreenTestLock.acquire()
        defer { TerminalScreenTestLock.release() }
        let session = TerminalPredictionInputTests.EchoSession()
        session.echoes = false
        session.connectionState = .reattaching(mac: nil)
        let model = TerminalModel(session: session, artifactSource: MockArtifactSource(), title: "cold")
        let screen = TerminalViewController(model: model)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = screen
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        try await TerminalPredictionInputTests.waitUntil(5) { session.handler != nil }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { _ in }
        model.restoreLastFrame(image)

        session.connection(.failed(message: "daemon channel closed"))
        try await Task.sleep(for: .milliseconds(300)) // test: the state change lands
        #expect(model.coldFrame != nil, "a failed attach keeps the page's cache")
        #expect(!model.connectionState.isAttached)
    }
}
#endif
