import Foundation
import Testing

@testable import CmuxMobileShell
import CmuxMobileShellModel

/// Scroll ownership and output classification for terminals the phone serves
/// itself: an external host's surfaces (a cmux Cloud machine) and
/// demonstration content.
///
/// The product rule these encode: the phone-local emulator holds the entire
/// terminal for these surfaces — its scrollback, its screen state, its bytes.
/// A scroll gesture is therefore always the phone's to apply, on the same
/// pixel-precise path a screen-anchored Mac session earns, and never a Mac
/// RPC; and the bytes feeding the emulator must never be gated behind the
/// foreground Mac's verified-replay pipeline, which can neither order nor
/// replay them.
@MainActor
struct ExternalHostScrollAuthorityTests {
    /// A source owning one host and its one terminal.
    private final class RecordingHost: MobileExternalHostSource {
        let hostID: String
        let surfaceID: String
        var replayRequests: [String] = []

        init(hostID: String, surfaceID: String) {
            self.hostID = hostID
            self.surfaceID = surfaceID
        }

        func externalHostOwnsSurface(_ surfaceID: String) -> Bool { surfaceID == self.surfaceID }
        func externalHostOwnsHost(_ hostID: String) -> Bool { hostID == self.hostID }
        func externalHostSendInput(_ text: String, surfaceID: String) {}
        func externalHostReportViewport(surfaceID: String, columns: Int, rows: Int) {}
        func externalHostRequestReplay(surfaceID: String) { replayRequests.append(surfaceID) }
    }

    private static let hostID = "cmux-cloud\u{1D}vm-1"
    private static let surfaceID = "cmux-cloud\u{1D}vm-1\u{1D}term-1"

    private static func state() -> MacWorkspaceState {
        MacWorkspaceState(
            macDeviceID: hostID,
            displayName: "sleepy-teal-otter",
            workspaces: [
                MobileWorkspacePreview(
                    id: MobileWorkspacePreview.ID(rawValue: "cmux-cloud\u{1D}vm-1\u{1D}ws-1"),
                    macDeviceID: hostID,
                    macDisplayName: "sleepy-teal-otter",
                    name: "api",
                    terminals: [
                        MobileTerminalPreview(
                            id: MobileTerminalPreview.ID(rawValue: surfaceID),
                            name: "zsh"
                        )
                    ]
                )
            ],
            status: .connected,
            workspaceSnapshotIsAuthoritative: true
        )
    }

    @discardableResult
    private static func install(
        _ host: RecordingHost,
        on composite: MobileShellComposite
    ) -> MobileShellComposite {
        composite.registerExternalHostSource(host)
        composite.applyExternalHostWorkspaceState(state())
        return composite
    }

    private static let screenAnchoredCapabilities: [String] = [
        "events.v1",
        "terminal.bytes.v1",
        "terminal.render_grid.v1",
        "terminal.render_grid.verified_replay.v1",
        "terminal.render_grid.screen_anchor.v1",
        "terminal.replay.v1"
    ]

    @Test("A locally served surface owns primary-screen scrolling with no Mac at all")
    func locallyServedSurfacesOwnPrimaryScrollWithoutAMac() {
        let host = RecordingHost(hostID: Self.hostID, surfaceID: Self.surfaceID)
        let composite = Self.install(host, on: MobileShellComposite(workspaces: []))

        // No Mac session, so no screen-anchored render grid — but the Cloud
        // terminal's scrollback lives in the phone's own emulator, which is
        // exactly what local pixel scrolling drives.
        #expect(composite.ownsLocalPrimaryScreenScroll(surfaceID: Self.surfaceID))
        // Demonstration terminals ride the same locally-fed emulator.
        #expect(composite.ownsLocalPrimaryScreenScroll(surfaceID: "cmux-demo-terminal-1"))
        // A Mac's surface stays on the Mac contract: unknown screen, no
        // screen-anchored session, no local ownership.
        #expect(!composite.ownsLocalPrimaryScreenScroll(surfaceID: "term-mac"))
    }

    @Test("A scroll on a locally served surface opens no Mac scroll queue")
    func scrollDoesNotEnterTheMacPipelineWithoutAMac() async {
        let host = RecordingHost(hostID: Self.hostID, surfaceID: Self.surfaceID)
        let composite = Self.install(host, on: MobileShellComposite(workspaces: []))

        await composite.scrollTerminal(surfaceID: Self.surfaceID, lines: 3, col: 0, row: 0)

        // The Mac pipeline queues one delivery per surface; staying empty is
        // the evidence the gesture never entered it.
        #expect(composite.terminalScrollQueuesBySurfaceID[Self.surfaceID] == nil)
    }

    @MainActor
    @Test("A connected screen-anchored Mac does not pull a Cloud surface's scroll into its RPC")
    func scrollStaysLocalBesideAConnectedMac() async throws {
        let router = LivenessHostRouter()
        await router.setCapabilities(Self.screenAnchoredCapabilities)
        let store = try await makeConnectedStore(
            router: router,
            box: TransportBox(),
            clock: TestClock()
        )
        try #require(store.usesScreenAnchoredRenderGrid)
        let host = RecordingHost(hostID: Self.hostID, surfaceID: Self.surfaceID)
        Self.install(host, on: store)

        // No render-grid frame ever confirms a Cloud surface's screen — the
        // Mac has never heard of it — so ownership must not hang on that
        // confirmation the way the Mac mirror's does.
        #expect(store.terminalActiveScreenBySurfaceID[Self.surfaceID] == nil)
        #expect(store.ownsLocalPrimaryScreenScroll(surfaceID: Self.surfaceID))

        await store.scrollTerminal(surfaceID: Self.surfaceID, lines: 3, col: 0, row: 0)
        #expect(store.terminalScrollQueuesBySurfaceID[Self.surfaceID] == nil)
        #expect(await router.count(of: "mobile.terminal.scroll") == 0)
    }

    @MainActor
    @Test("A verified-replay Mac without screen anchoring cannot demote a Cloud surface's scroll authority")
    func presentationAuthorityIsPerSurface() async throws {
        let router = LivenessHostRouter()
        // Verified replay WITHOUT the screen-anchor capability (and without a
        // byte lane, which would negotiate hybrid instead): the one Mac
        // configuration whose surfaces must wait for the Mac's ordered frame.
        await router.setCapabilities([
            "events.v1",
            "terminal.render_grid.v1",
            "terminal.render_grid.verified_replay.v1",
            "terminal.replay.v1"
        ])
        let store = try await makeConnectedStore(
            router: router,
            box: TransportBox(),
            clock: TestClock()
        )
        try #require(store.usesVerifiedTerminalReplay)
        try #require(!store.usesScreenAnchoredRenderGrid)
        let host = RecordingHost(hostID: Self.hostID, surfaceID: Self.surfaceID)
        Self.install(host, on: store)

        // The Mac's surfaces defer to the Mac's ordered frames...
        #expect(!store.terminalScrollPresentationAppliesLocally(surfaceID: "term-mac"))
        // ...but a Cloud surface has no Mac frame to defer to: demoting it
        // with the session leaves its scroll gesture with no applier at all.
        #expect(store.terminalScrollPresentationAppliesLocally(surfaceID: Self.surfaceID))
        #expect(store.terminalScrollPresentationAppliesLocally(surfaceID: "cmux-demo-terminal-1"))

        // With no Mac connected everything presents locally.
        let offline = Self.install(
            RecordingHost(hostID: Self.hostID, surfaceID: Self.surfaceID),
            on: MobileShellComposite(workspaces: [])
        )
        #expect(offline.terminalScrollPresentationAppliesLocally(surfaceID: Self.surfaceID))
        #expect(offline.terminalScrollPresentationAppliesLocally(surfaceID: "term-mac"))
    }

    @MainActor
    @Test("A render-grid Mac session does not gate a Cloud surface's bytes behind verified replay")
    func externalBytesAreNotHeldToVerifiedReplay() async throws {
        let router = LivenessHostRouter()
        await router.setCapabilities(Self.screenAnchoredCapabilities)
        let store = try await makeConnectedStore(
            router: router,
            box: TransportBox(),
            clock: TestClock()
        )
        try #require(store.usesVerifiedTerminalReplay)
        let host = RecordingHost(hostID: Self.hostID, surfaceID: Self.surfaceID)
        Self.install(host, on: store)

        // Mounting the Cloud terminal registers its output stream; the
        // external-host fence answers the cold attach (and releases any
        // replay barrier) from the host itself.
        let stream = store.terminalOutputStream(
            surfaceID: Self.surfaceID,
            ownerID: UUID(),
            releaseViewportOnTermination: false
        )
        #expect(host.replayRequests == [Self.surfaceID])

        let delivered = store.deliverExternalHostTerminalBytes(
            Data("hello from the daemon".utf8),
            surfaceID: Self.surfaceID
        )
        #expect(delivered)

        var first: MobileTerminalOutputChunk?
        for await chunk in stream {
            first = chunk
            break
        }
        let chunk = try #require(first)
        // Verified replay verifies Mac-ordered frames. A locally served
        // surface has no Mac ordering; holding its bytes to that gate makes
        // the consumer freeze the presentation and loop on replays, so the
        // surface would never paint while a render-grid Mac is foreground.
        #expect(!chunk.requiresVerifiedReplay)
    }
}
