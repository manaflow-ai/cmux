import CmuxMobileCloud
import CmuxMobileShell
import Foundation
import Testing

@testable import CmuxMobileCloudBridge

/// Attachment behavior of the bridge, driven through the link seam so no
/// tunnel, daemon or VM is involved.
///
/// These cover the three things that were wrong before: input typed while a
/// link was coming up, a repaint request restarting an attach already running,
/// and teardown releasing only part of an attachment.
@MainActor
struct CloudAttachmentBehaviorTests {
    /// One terminal's input side, recording what the bridge sends it.
    private final class FakeLink: CloudTerminalLinking, @unchecked Sendable {
        private let lock = NSLock()
        private var _sent: [Data] = []
        private var _resizes: [(cols: Int, rows: Int)] = []
        private var _detachCount = 0

        var sent: [Data] { lock.withLock { _sent } }
        var sentText: String { sent.map { String(decoding: $0, as: UTF8.self) }.joined() }
        var resizes: [(cols: Int, rows: Int)] { lock.withLock { _resizes } }
        var detachCount: Int { lock.withLock { _detachCount } }

        func send(_ bytes: Data) { lock.withLock { _sent.append(bytes) } }
        func resize(cols: Int, rows: Int) { lock.withLock { _resizes.append((cols, rows)) } }
        func detach() { lock.withLock { _detachCount += 1 } }
    }

    /// Holds attaches open the way the real library does: a blocking dial
    /// that task cancellation cannot interrupt. An AsyncStream gate would
    /// release its waiter the moment the bridge cancels a superseded attach,
    /// which is exactly the behavior the library does not have.
    final class BlockingGate: @unchecked Sendable {
        private let lock = NSLock()
        private var waiters: [UnsafeContinuation<Void, Never>] = []
        private var isFinished = false

        func wait() async {
            await withUnsafeContinuation { continuation in
                lock.lock()
                if isFinished {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                waiters.append(continuation)
                lock.unlock()
            }
        }

        /// Releases one held dial.
        func open() {
            lock.lock()
            let next = waiters.isEmpty ? nil : waiters.removeFirst()
            lock.unlock()
            next?.resume()
        }

        /// Releases every held and future dial.
        func finish() {
            lock.lock()
            isFinished = true
            let held = waiters
            waiters = []
            lock.unlock()
            for waiter in held { waiter.resume() }
        }
    }

    /// One machine's link. `attachGate` lets a test hold an attach open so the
    /// window where no attachment exists yet is observable.
    private final class FakeMachineLink: CloudMachineLinking, @unchecked Sendable {
        let terminalLink = FakeLink()
        private let lock = NSLock()
        private var _attachedTerminalIDs: [String] = []
        private var _outputSinks: [@Sendable (CloudTerminalOutputEvent) -> Void] = []
        var attachGate: BlockingGate?

        var attachedTerminalIDs: [String] { lock.withLock { _attachedTerminalIDs } }
        var attachCount: Int { attachedTerminalIDs.count }

        func emit(_ event: CloudTerminalOutputEvent) {
            let sinks = lock.withLock { _outputSinks }
            for sink in sinks { sink(event) }
        }

        func createWorkspace(name: String?) async -> String? { nil }
        func createTerminal(inWorkspace workspaceID: String, name: String?) async -> String? { nil }

        func loadCatalog() async throws -> (
            workspaces: [CloudWorkspaceSummary],
            terminals: [CloudTerminalSummary]
        ) {
            (
                [CloudWorkspaceSummary(id: "ws-1", name: "api")],
                [CloudTerminalSummary(id: "t-1", name: "zsh", workspaceID: "ws-1")]
            )
        }

        func attach(
            terminalID: String,
            output: @escaping @Sendable (CloudTerminalOutputEvent) -> Void
        ) async throws -> any CloudTerminalLinking {
            lock.withLock { _attachedTerminalIDs.append(terminalID) }
            if let gate = attachGate {
                await gate.wait()
            }
            lock.withLock { _outputSinks.append(output) }
            return terminalLink
        }
    }

    private final class FakeLinkProvider: CloudMachineLinkProviding {
        var linksByMachineID: [String: FakeMachineLink] = [:]
        private(set) var linkRequestCount = 0

        func resetLink(for machine: CloudMachine) {}
        /// When false, the tunnel is treated as not ready.
        var isReady = true

        func link(for machine: CloudMachine) -> (any CloudMachineLinking)? {
            linkRequestCount += 1
            guard isReady else { return nil }
            return linksByMachineID[machine.id]
        }
    }

    private static func machine(id: String = "vm-1") -> CloudMachine {
        CloudMachine(id: id, provider: "freestyle", status: "running", displayName: "otter")
    }

    private static func surfaceID(machineID: String = "vm-1", terminal: String = "t-1") -> String {
        CloudAddress(machineID: machineID, component: terminal).identifier
    }

    /// Lets queued main-actor work run until the state under test is visible.
    private func settle(
        until condition: () -> Bool,
        timeout: Duration = .seconds(10)
    ) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition(), ContinuousClock.now < deadline {
            await Task.yield()
        }
    }

    private func makeBridge(
        gateAttach: Bool = false
    ) async -> (CloudWorkspaceBridge, FakeLinkProvider, FakeMachineLink) {
        let link = FakeMachineLink()
        if gateAttach {
            link.attachGate = BlockingGate()
        }
        let provider = FakeLinkProvider()
        provider.linksByMachineID["vm-1"] = link
        let bridge = CloudWorkspaceBridge(links: provider)
        bridge.setAdmittedMachines([Self.machine()])
        return (bridge, provider, link)
    }

    @Test("Input typed while the link is coming up is delivered in order, not dropped")
    func inputBeforeAttachIsHeld() async {
        let (bridge, _, link) = await makeBridge(gateAttach: true)
        let surface = Self.surfaceID()

        // The view is on screen and the user types before the attach finishes.
        bridge.externalHostSendInput("ec", surfaceID: surface)
        bridge.externalHostSendInput("ho hi\r", surfaceID: surface)
        await settle(until: { link.attachCount == 1 })
        #expect(link.terminalLink.sent.isEmpty, "nothing can be sent before the link exists")

        // Let the attach complete.
        link.attachGate?.finish()
        await settle(until: { !link.terminalLink.sent.isEmpty })

        #expect(link.terminalLink.sentText == "echo hi\r")
    }

    @Test("A grid reported before the attach is replayed once the link is up")
    func viewportBeforeAttachIsReplayed() async {
        let (bridge, _, link) = await makeBridge(gateAttach: true)
        let surface = Self.surfaceID()

        bridge.externalHostRequestReplay(surfaceID: surface)
        bridge.externalHostReportViewport(surfaceID: surface, columns: 96, rows: 30)
        await settle(until: { link.attachCount == 1 })
        #expect(link.terminalLink.resizes.isEmpty)

        link.attachGate?.finish()
        await settle(until: { !link.terminalLink.resizes.isEmpty })

        #expect(link.terminalLink.resizes.map(\.cols) == [96])
        #expect(link.terminalLink.resizes.map(\.rows) == [30])
    }

    @Test("Repeated repaint requests do not restart an attach already running")
    func repeatedReplayDoesNotThrashTheLink() async {
        let (bridge, _, link) = await makeBridge(gateAttach: true)
        let surface = Self.surfaceID()

        bridge.externalHostRequestReplay(surfaceID: surface)
        bridge.externalHostRequestReplay(surfaceID: surface)
        bridge.externalHostRequestReplay(surfaceID: surface)
        await settle(until: { link.attachCount == 1 })

        #expect(link.attachCount == 1)
        #expect(link.terminalLink.detachCount == 0)
    }

    @Test("Once attached, a repaint request reattaches to get a fresh snapshot")
    func replayAfterAttachReattaches() async {
        let (bridge, _, link) = await makeBridge()
        let surface = Self.surfaceID()

        // Wait for the link to be live rather than merely requested: input
        // arriving proves the attachment exists, which is the state a second
        // repaint request has to act against.
        bridge.externalHostRequestReplay(surfaceID: surface)
        bridge.externalHostSendInput("x", surfaceID: surface)
        await settle(until: { !link.terminalLink.sent.isEmpty })
        #expect(link.attachCount == 1)

        // A view reset needs the daemon's whole screen again, which only a
        // fresh attach produces.
        bridge.externalHostRequestReplay(surfaceID: surface)
        await settle(until: { link.attachCount == 2 })
        #expect(link.attachCount == 2)
        #expect(link.terminalLink.detachCount == 1)
    }

    @Test("Switching terminals mid-attach hands the slot over in order")
    func supersededAttachHandsOverInOrder() async {
        let (bridge, provider, link) = await makeBridge(gateAttach: true)
        let first = Self.surfaceID(terminal: "t-1")
        let second = Self.surfaceID(terminal: "t-2")

        bridge.externalHostRequestReplay(surfaceID: first)
        await settle(until: { link.attachedTerminalIDs == ["t-1"] })

        // Supersede while the first dial is still blocked in the library.
        let linkRequestsBeforeSecond = provider.linkRequestCount
        bridge.externalHostRequestReplay(surfaceID: second)
        // The successor must NOT dial concurrently; it waits out the first.
        await settle(until: { provider.linkRequestCount == linkRequestsBeforeSecond + 1 })
        #expect(link.attachedTerminalIDs == ["t-1"])

        // Releasing the first dial lets it finish as superseded: it frees the
        // machine's slot (one detach) BEFORE the successor dials.
        link.attachGate?.open()
        await settle(until: { link.attachedTerminalIDs == ["t-1", "t-2"] })
        #expect(link.terminalLink.detachCount == 1)

        // Input typed while the successor is still dialing is held for it.
        bridge.externalHostSendInput("whoami\n", surfaceID: second)
        link.attachGate?.open()
        await settle(until: { link.terminalLink.sentText.contains("whoami") })
        #expect(link.terminalLink.sentText == "whoami\n")
        #expect(link.terminalLink.detachCount == 1)
    }

    @Test("Retiring a machine detaches it and drops its held input")
    func retiringDetaches() async {
        let (bridge, _, link) = await makeBridge(gateAttach: true)
        let surface = Self.surfaceID()

        bridge.externalHostSendInput("ls\r", surfaceID: surface)
        await settle(until: { link.attachCount == 1 })

        bridge.setAdmittedMachines([])
        link.attachGate?.finish()
        await settle(until: { link.terminalLink.detachCount == 1 })

        // The surface is no longer owned, so nothing more can be routed to it.
        #expect(!bridge.externalHostOwnsSurface(surface))
        bridge.externalHostSendInput("more\r", surfaceID: surface)
        #expect(!link.terminalLink.sentText.contains("more"))
    }

    @Test("Losing the tunnel drops attachments so input is not sent into a dead link")
    func tunnelLossDropsAttachments() async {
        let (bridge, provider, link) = await makeBridge()
        let surface = Self.surfaceID()

        bridge.externalHostRequestReplay(surfaceID: surface)
        bridge.externalHostSendInput("first\r", surfaceID: surface)
        await settle(until: { link.terminalLink.sentText == "first\r" })
        #expect(link.terminalLink.sentText == "first\r")
        #expect(link.attachCount == 1)

        // Backgrounding stops the tunnel, and the controller closes its links.
        provider.isReady = false
        bridge.linksDidBecomeUnavailable()
        await settle(until: { link.terminalLink.detachCount == 1 })
        #expect(link.terminalLink.detachCount == 1)

        // Typing now must not be handed to the dead attachment.
        bridge.externalHostSendInput("lost\r", surfaceID: surface)
        #expect(!link.terminalLink.sentText.contains("lost"))

        // Once the tunnel is back, the next interaction attaches again and the
        // input reaches the terminal.
        provider.isReady = true
        bridge.externalHostSendInput("after\r", surfaceID: surface)
        await settle(until: { link.attachCount == 2 && link.terminalLink.sentText.contains("after") })
        #expect(link.attachCount == 2)
        #expect(link.terminalLink.sentText.contains("after\r"))
    }

    @Test("A surface on a machine that is not admitted is disowned")
    func unknownMachineIsDisowned() async {
        let (bridge, _, _) = await makeBridge()
        #expect(!bridge.externalHostOwnsSurface(Self.surfaceID(machineID: "vm-absent")))
        #expect(bridge.externalHostOwnsSurface(Self.surfaceID()))
    }

    @Test("With no tunnel the machine is still published, as reconnecting")
    func noTunnelStillPublishes() async {
        let link = FakeMachineLink()
        let provider = FakeLinkProvider()
        provider.linksByMachineID["vm-1"] = link
        provider.isReady = false
        let bridge = CloudWorkspaceBridge(links: provider)
        bridge.setAdmittedMachines([Self.machine()])

        #expect(link.attachCount == 0)
        #expect(bridge.admittedMachines.map(\.id) == ["vm-1"])
    }
}

/// Which store the bridge publishes into, across composition-root re-renders
/// and sign-out.
@MainActor
struct CloudBridgeStoreLifetimeTests {
    private final class NoLinks: CloudMachineLinkProviding {
        func link(for machine: CloudMachine) -> (any CloudMachineLinking)? { nil }
        func resetLink(for machine: CloudMachine) {}
    }

    private static let machine = CloudMachine(
        id: "vm-1", provider: "freestyle", status: "running", displayName: "otter"
    )
    private static var hostID: String { CloudAddress(machineID: "vm-1").identifier }

    @Test("A re-render's throwaway store never steals the live one")
    func firstLiveStoreWins() {
        let bridge = CloudWorkspaceBridge(links: NoLinks())
        let live = MobileShellComposite(workspaces: [])
        bridge.attach(to: live)

        // A second store built by a re-render, then discarded.
        do {
            let throwaway = MobileShellComposite(workspaces: [])
            bridge.attach(to: throwaway)
        }

        bridge.setAdmittedMachines([Self.machine])
        #expect(live.externalHostSummaries.map(\.hostID) == [Self.hostID])
    }

    @Test("A paused machine is shown unreachable and never dialed")
    func pausedMachineIsNotDialed() {
        final class CountingLinks: CloudMachineLinkProviding {
            var requests = 0
            func resetLink(for machine: CloudMachine) {}
            func link(for machine: CloudMachine) -> (any CloudMachineLinking)? {
                requests += 1
                return nil
            }
        }
        let links = CountingLinks()
        let bridge = CloudWorkspaceBridge(links: links)
        let store = MobileShellComposite(workspaces: [])
        bridge.attach(to: store)

        bridge.setAdmittedMachines([
            CloudMachine(id: "vm-1", provider: "freestyle", status: "paused", displayName: "otter"),
        ])

        #expect(links.requests == 0)
        #expect(store.externalHostSummaries.first?.status == .unavailable)
    }

    @Test("Sign-out clears rows but stays attached for the next sign-in")
    func signOutThenSignInPublishesAgain() {
        let bridge = CloudWorkspaceBridge(links: NoLinks())
        let store = MobileShellComposite(workspaces: [])
        bridge.attach(to: store)
        bridge.setAdmittedMachines([Self.machine])
        #expect(!store.externalHostSummaries.isEmpty)

        bridge.resetForSignOut()
        #expect(store.externalHostSummaries.isEmpty)

        bridge.setAdmittedMachines([Self.machine])
        #expect(store.externalHostSummaries.map(\.hostID) == [Self.hostID])
    }
}

/// Hiding a Cloud machine from the Computers screen persists across launches.
@MainActor
struct CloudVisibilityPersistenceTests {
    private final class NoLinks: CloudMachineLinkProviding {
        func link(for machine: CloudMachine) -> (any CloudMachineLinking)? { nil }
        func resetLink(for machine: CloudMachine) {}
    }

    private final class MemoryVisibility: CloudMachineVisibilityStoring {
        var hiddenMachineIDs: Set<String> = []
        func setMachine(id: String, hidden: Bool) {
            if hidden { hiddenMachineIDs.insert(id) } else { hiddenMachineIDs.remove(id) }
        }
    }

    private static let machine = CloudMachine(
        id: "vm-1", provider: "freestyle", status: "paused", displayName: "otter"
    )
    private static var hostID: String { CloudAddress(machineID: "vm-1").identifier }

    @Test("Hiding in the store is persisted, and a fresh launch restores it")
    func hidePersistsAcrossLaunch() {
        let persisted = MemoryVisibility()

        // First launch: the user hides the machine.
        do {
            let bridge = CloudWorkspaceBridge(links: NoLinks(), visibility: persisted)
            let store = MobileShellComposite(workspaces: [])
            bridge.attach(to: store)
            bridge.setAdmittedMachines([Self.machine])
            store.setExternalHost(Self.hostID, hidden: true)
        }
        #expect(persisted.hiddenMachineIDs == ["vm-1"])

        // Relaunch: a new store and bridge over the same persistence.
        let bridge = CloudWorkspaceBridge(links: NoLinks(), visibility: persisted)
        let store = MobileShellComposite(workspaces: [])
        bridge.attach(to: store)
        bridge.setAdmittedMachines([Self.machine])

        #expect(store.externalHostIsHidden(Self.hostID))
        #expect(store.externalHostSummaries.first?.isHidden == true)
    }

    @Test("Revealing again is persisted too")
    func revealPersists() {
        let persisted = MemoryVisibility()
        persisted.hiddenMachineIDs = ["vm-1"]
        let bridge = CloudWorkspaceBridge(links: NoLinks(), visibility: persisted)
        let store = MobileShellComposite(workspaces: [])
        bridge.attach(to: store)
        bridge.setAdmittedMachines([Self.machine])
        #expect(store.externalHostIsHidden(Self.hostID))

        store.setExternalHost(Self.hostID, hidden: false)

        #expect(persisted.hiddenMachineIDs.isEmpty)
        #expect(!store.externalHostIsHidden(Self.hostID))
    }
}
