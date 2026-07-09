import Foundation
import Testing
@testable import CmuxNotifications

/// A controllable fake panel: tracks sends and lets a test flip readiness mid-flow.
@MainActor
private final class FakePanel: TerminalTextSendPanel {
    let panelID: UUID
    var isAgentHibernated: Bool
    var isSurfaceReady: Bool
    var sendShouldSucceed: Bool
    private(set) var sentTexts: [String] = []
    private(set) var inputDemandRequests = 0

    init(
        panelID: UUID = UUID(),
        isAgentHibernated: Bool = false,
        isSurfaceReady: Bool = false,
        sendShouldSucceed: Bool = true
    ) {
        self.panelID = panelID
        self.isAgentHibernated = isAgentHibernated
        self.isSurfaceReady = isSurfaceReady
        self.sendShouldSucceed = sendShouldSucceed
    }

    func requestInputDemandSurfaceStartIfNeeded() { inputDemandRequests += 1 }

    @discardableResult
    func sendText(_ text: String) -> Bool {
        sentTexts.append(text)
        return sendShouldSucceed
    }
}

@MainActor
private final class FakeCancellable: TerminalTextSendCancellable {
    private(set) var cancelCount = 0
    func cancel() { cancelCount += 1 }
}

/// A fake target that records observer registrations and lets the test fire each
/// readiness signal and the timeout on demand. `resolvePanel` is re-evaluated on
/// every call so a test can swap the resolved panel mid-flow.
@MainActor
private final class FakeTarget: TerminalTextSendTarget {
    let workspaceID = UUID()
    var resolvePanel: () -> FakePanel?

    var panelsHandler: (@MainActor () -> Void)?
    var surfaceReadyHandler: (@MainActor (UUID?) -> Void)?
    var focusHandler: (@MainActor (UUID) -> Void)?
    var firstResponderHandler: (@MainActor (UUID) -> Void)?
    var timeoutHandler: (@MainActor () -> Void)?
    private(set) var timeoutSeconds: TimeInterval?

    let panelsToken = FakeCancellable()
    let surfaceReadyToken = FakeCancellable()
    let focusToken = FakeCancellable()
    let firstResponderToken = FakeCancellable()
    let timeoutToken = FakeCancellable()

    init(resolvePanel: @escaping () -> FakePanel?) {
        self.resolvePanel = resolvePanel
    }

    func resolveSendPanel(preferredPanelID: UUID?) -> (any TerminalTextSendPanel)? {
        resolvePanel()
    }

    func observePanelsChanged(_ handler: @escaping @MainActor () -> Void) -> any TerminalTextSendCancellable {
        panelsHandler = handler
        return panelsToken
    }

    func observeSurfaceReady(_ handler: @escaping @MainActor (UUID?) -> Void) -> any TerminalTextSendCancellable {
        surfaceReadyHandler = handler
        return surfaceReadyToken
    }

    func observeDidFocusSurface(_ handler: @escaping @MainActor (UUID) -> Void) -> any TerminalTextSendCancellable {
        focusHandler = handler
        return focusToken
    }

    func observeDidBecomeFirstResponderSurface(_ handler: @escaping @MainActor (UUID) -> Void) -> any TerminalTextSendCancellable {
        firstResponderHandler = handler
        return firstResponderToken
    }

    func scheduleTimeout(after seconds: TimeInterval, _ handler: @escaping @MainActor () -> Void) -> any TerminalTextSendCancellable {
        timeoutSeconds = seconds
        timeoutHandler = handler
        return timeoutToken
    }
}

@Suite(.serialized)
@MainActor
struct TerminalTextSendCoordinatorTests {
    @Test("hibernated panel sends immediately without registering observers")
    func hibernatedImmediate() {
        let panel = FakePanel(isAgentHibernated: true)
        let target = FakeTarget { panel }
        var beforeSendCount = 0
        let coordinator = TerminalTextSendCoordinator()

        coordinator.send("hi", to: target, beforeSend: { beforeSendCount += 1 })

        #expect(panel.sentTexts == ["hi"])
        #expect(beforeSendCount == 1)
        #expect(target.surfaceReadyHandler == nil)
        #expect(panel.inputDemandRequests == 0)
    }

    @Test("ready surface sends immediately")
    func readyImmediate() {
        let panel = FakePanel(isSurfaceReady: true)
        let target = FakeTarget { panel }
        let coordinator = TerminalTextSendCoordinator()

        coordinator.send("echo", to: target)

        #expect(panel.sentTexts == ["echo"])
        #expect(target.surfaceReadyHandler == nil)
    }

    @Test("not-ready surface waits, requests input demand, and arms a 3s timeout")
    func notReadyArmsObservers() {
        let panel = FakePanel(isSurfaceReady: false)
        let target = FakeTarget { panel }
        let coordinator = TerminalTextSendCoordinator()

        coordinator.send("later", to: target)

        #expect(panel.sentTexts.isEmpty)
        #expect(panel.inputDemandRequests == 1)
        #expect(target.surfaceReadyHandler != nil)
        #expect(target.timeoutSeconds == 3.0)
    }

    @Test("surface-ready signal triggers the delayed send and tears observers down")
    func surfaceReadyTriggersDelayedSend() {
        let panel = FakePanel(isSurfaceReady: false)
        let target = FakeTarget { panel }
        let coordinator = TerminalTextSendCoordinator()

        coordinator.send("payload", to: target)
        panel.isSurfaceReady = true
        target.surfaceReadyHandler?(nil)

        #expect(panel.sentTexts == ["payload"])
        #expect(target.surfaceReadyToken.cancelCount == 1)
        #expect(target.panelsToken.cancelCount == 1)
    }

    @Test("surface-ready for a non-preferred surface is ignored")
    func nonPreferredSurfaceReadyIgnored() {
        let preferred = UUID()
        let panel = FakePanel(panelID: preferred, isSurfaceReady: false)
        let target = FakeTarget { panel }
        let coordinator = TerminalTextSendCoordinator()

        coordinator.send("p", to: target, preferredPanelID: preferred)
        panel.isSurfaceReady = true
        // A different surface became ready: must not send.
        target.surfaceReadyHandler?(UUID())
        #expect(panel.sentTexts.isEmpty)

        // The preferred surface becoming ready does send.
        target.surfaceReadyHandler?(preferred)
        #expect(panel.sentTexts == ["p"])
    }

    @Test("timeout before readiness fails and cleans up; later signals do not double-send")
    func timeoutFailsThenNoDoubleSend() {
        let panel = FakePanel(isSurfaceReady: false)
        let target = FakeTarget { panel }
        var failureCount = 0
        let coordinator = TerminalTextSendCoordinator()

        coordinator.send("x", to: target, onFailure: { failureCount += 1 })
        target.timeoutHandler?()

        #expect(failureCount == 1)
        #expect(panel.sentTexts.isEmpty)
        #expect(target.surfaceReadyToken.cancelCount == 1)

        // A surface-ready arriving after the timeout latch must not send.
        panel.isSurfaceReady = true
        target.surfaceReadyHandler?(nil)
        #expect(panel.sentTexts.isEmpty)
    }

    @Test("panels-changed re-checks readiness and sends when newly ready")
    func panelsChangedTriggersSend() {
        let panel = FakePanel(isSurfaceReady: false)
        let target = FakeTarget { panel }
        let coordinator = TerminalTextSendCoordinator()

        coordinator.send("q", to: target)
        panel.isSurfaceReady = true
        target.panelsHandler?()

        #expect(panel.sentTexts == ["q"])
    }
}
