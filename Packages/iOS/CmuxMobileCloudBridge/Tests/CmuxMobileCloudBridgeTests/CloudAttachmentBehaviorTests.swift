import CmuxMobileCloud
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

    /// One machine's link. `attachGate` lets a test hold an attach open so the
    /// window where no attachment exists yet is observable.
    private final class FakeMachineLink: CloudMachineLinking, @unchecked Sendable {
        let terminalLink = FakeLink()
        private let lock = NSLock()
        private var _attachedTerminalIDs: [String] = []
        private var _outputSinks: [@Sendable (CloudTerminalOutputEvent) -> Void] = []
        var attachGate: (stream: AsyncStream<Void>, continuation: AsyncStream<Void>.Continuation)?

        var attachedTerminalIDs: [String] { lock.withLock { _attachedTerminalIDs } }
        var attachCount: Int { attachedTerminalIDs.count }

        func emit(_ event: CloudTerminalOutputEvent) {
            let sinks = lock.withLock { _outputSinks }
            for sink in sinks { sink(event) }
        }

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
                var iterator = gate.stream.makeAsyncIterator()
                _ = await iterator.next()
            }
            lock.withLock { _outputSinks.append(output) }
            return terminalLink
        }
    }

    private final class FakeLinkProvider: CloudMachineLinkProviding {
        var linksByMachineID: [String: FakeMachineLink] = [:]
        /// When false, the tunnel is treated as not ready.
        var isReady = true

        func link(for machine: CloudMachine) -> (any CloudMachineLinking)? {
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

    /// Lets queued main-actor work and the bridge's attach task run.
    ///
    /// A fixed yield count is a race under load, so a wait for something to
    /// happen polls its own condition and only gives up after a bound that is
    /// far past any real scheduling delay. Waits that assert nothing happens
    /// still need a plain settle, which is why both exist.
    private func settle(
        until condition: () -> Bool = { false },
        iterations: Int = 2_000
    ) async {
        for _ in 0..<iterations {
            if condition() { return }
            await Task.yield()
        }
    }

    private func makeBridge(
        gateAttach: Bool = false
    ) async -> (CloudWorkspaceBridge, FakeLinkProvider, FakeMachineLink) {
        let link = FakeMachineLink()
        if gateAttach {
            link.attachGate = AsyncStream<Void>.makeStream()
        }
        let provider = FakeLinkProvider()
        provider.linksByMachineID["vm-1"] = link
        let bridge = CloudWorkspaceBridge(links: provider)
        bridge.setAdmittedMachines([Self.machine()])
        await settle()
        return (bridge, provider, link)
    }

    @Test("Input typed while the link is coming up is delivered in order, not dropped")
    func inputBeforeAttachIsHeld() async {
        let (bridge, _, link) = await makeBridge(gateAttach: true)
        let surface = Self.surfaceID()

        // The view is on screen and the user types before the attach finishes.
        bridge.externalHostSendInput("ec", surfaceID: surface)
        bridge.externalHostSendInput("ho hi\r", surfaceID: surface)
        await settle()
        #expect(link.terminalLink.sent.isEmpty, "nothing can be sent before the link exists")

        // Let the attach complete.
        link.attachGate?.continuation.finish()
        await settle(until: { !link.terminalLink.sent.isEmpty })

        #expect(link.terminalLink.sentText == "echo hi\r")
    }

    @Test("A grid reported before the attach is replayed once the link is up")
    func viewportBeforeAttachIsReplayed() async {
        let (bridge, _, link) = await makeBridge(gateAttach: true)
        let surface = Self.surfaceID()

        bridge.externalHostRequestReplay(surfaceID: surface)
        bridge.externalHostReportViewport(surfaceID: surface, columns: 96, rows: 30)
        await settle()
        #expect(link.terminalLink.resizes.isEmpty)

        link.attachGate?.continuation.finish()
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
        await settle()

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

    @Test("Retiring a machine detaches it and drops its held input")
    func retiringDetaches() async {
        let (bridge, _, link) = await makeBridge(gateAttach: true)
        let surface = Self.surfaceID()

        bridge.externalHostSendInput("ls\r", surfaceID: surface)
        await settle()

        bridge.setAdmittedMachines([])
        link.attachGate?.continuation.finish()
        await settle()

        // The surface is no longer owned, so nothing more can be routed to it.
        #expect(!bridge.externalHostOwnsSurface(surface))
        bridge.externalHostSendInput("more\r", surfaceID: surface)
        await settle()
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
        await settle()
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
        await settle()

        #expect(link.attachCount == 0)
        #expect(bridge.admittedMachines.map(\.id) == ["vm-1"])
    }
}
