import Foundation
import Testing

@testable import CmuxMobileShell
import CmuxMobileShellModel

/// Behavior tests for a host that is not a paired Mac contributing workspaces
/// and serving terminals (a cmux Cloud machine).
///
/// The product rule these encode: such a host reuses the workspace experience
/// exactly, and reuses none of the Mac mechanisms. Its rows must appear in the
/// ordinary aggregated list, and its terminals must never be handed to the Mac
/// RPC pipeline, which knows nothing about them.
@MainActor
struct ExternalHostHostingTests {
    /// A source owning one host and its one terminal, recording what the store
    /// routes to it.
    private final class RecordingHost: MobileExternalHostSource {
        let hostID: String
        let surfaceID: String
        var sentInput: [String] = []
        var replayRequests: [String] = []
        var viewportReports: [(columns: Int, rows: Int)] = []

        init(hostID: String, surfaceID: String) {
            self.hostID = hostID
            self.surfaceID = surfaceID
        }

        func externalHostOwnsSurface(_ surfaceID: String) -> Bool { surfaceID == self.surfaceID }
        func externalHostOwnsHost(_ hostID: String) -> Bool { hostID == self.hostID }
        func externalHostSendInput(_ text: String, surfaceID: String) { sentInput.append(text) }
        func externalHostReportViewport(surfaceID: String, columns: Int, rows: Int) {
            viewportReports.append((columns, rows))
        }
        func externalHostRequestReplay(surfaceID: String) { replayRequests.append(surfaceID) }
    }

    private static let hostID = "cmux-cloud\u{1D}vm-1"
    private static let surfaceID = "cmux-cloud\u{1D}vm-1\u{1D}term-1"

    private static func state(workspaceName: String = "api") -> MacWorkspaceState {
        MacWorkspaceState(
            macDeviceID: hostID,
            displayName: "sleepy-teal-otter",
            workspaces: [
                MobileWorkspacePreview(
                    id: MobileWorkspacePreview.ID(rawValue: "cmux-cloud\u{1D}vm-1\u{1D}ws-1"),
                    macDeviceID: hostID,
                    macDisplayName: "sleepy-teal-otter",
                    name: workspaceName,
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

    private static func composite(with host: RecordingHost) -> MobileShellComposite {
        let composite = MobileShellComposite(workspaces: [])
        composite.registerExternalHostSource(host)
        composite.applyExternalHostWorkspaceState(state())
        return composite
    }

    @Test("An external host's terminal resolves to its row, so its view can start output")
    func terminalResolvesForOutputStart() {
        let host = RecordingHost(hostID: Self.hostID, surfaceID: Self.surfaceID)
        let composite = Self.composite(with: host)

        // The terminal view opens its output only once this resolves; nil
        // leaves a mounted Cloud terminal blank forever.
        #expect(composite.workspaceID(forTerminalID: Self.surfaceID) != nil)
        #expect(composite.workspaceID(forTerminalID: Self.surfaceID) == composite.workspaces.first?.id)
        #expect(
            composite.prepareTerminalViewport(surfaceID: Self.surfaceID, columns: 80, rows: 24) != nil
        )
    }

    @Test("Mounting an external host's terminal asks the host for its screen, with no Mac connected")
    func mountRequestsTheScreenFromTheHost() {
        let host = RecordingHost(hostID: Self.hostID, surfaceID: Self.surfaceID)
        let composite = Self.composite(with: host)

        // Registering the mounted view's output is its cold attach. Without a
        // Mac client the Mac path parks the request until a Mac connects,
        // which for a Cloud terminal is never, so the view stays blank.
        let stream = composite.terminalOutputStream(
            surfaceID: Self.surfaceID,
            ownerID: UUID(),
            releaseViewportOnTermination: false
        )
        #expect(host.replayRequests == [Self.surfaceID])
        _ = stream
    }

    @Test("A paired Mac's connection teardown leaves an external host's liveness alone")
    func macTeardownDoesNotDowngradeExternalHost() {
        let host = RecordingHost(hostID: Self.hostID, surfaceID: Self.surfaceID)
        let composite = Self.composite(with: host)
        #expect(composite.externalHostSummaries.first?.status == .connected)

        // A Mac reconnect loop runs this on every attempt. Downgrading the
        // Cloud host with it showed its terminal as Disconnected and blocked
        // its keyboard while the Cloud link itself was healthy.
        composite.clearRemoteConnectionContext()
        #expect(composite.externalHostSummaries.first?.status == .connected)
        #expect(composite.workspaces.first?.macConnectionStatus == .connected)

        composite.markSecondaryMacUnavailable(
            MacPairingKey(macDeviceID: Self.hostID, instanceTag: nil)
        )
        #expect(composite.externalHostSummaries.first?.status == .connected)
    }

    @Test("A team switch leaves an external host's rows to their source")
    func teamSwitchKeepsExternalHostRows() {
        let host = RecordingHost(hostID: Self.hostID, surfaceID: Self.surfaceID)
        let composite = Self.composite(with: host)

        composite.currentTeamDidChange()
        #expect(composite.externalHostSummaries.map(\.hostID) == [Self.hostID])
    }

    @Test("An external host's workspaces join the ordinary aggregated list")
    func rowsAppear() {
        let host = RecordingHost(hostID: Self.hostID, surfaceID: Self.surfaceID)
        let composite = Self.composite(with: host)

        #expect(composite.workspaces.count == 1)
        let row = try! #require(composite.workspaces.first)
        #expect(row.name == "api")
        #expect(row.macDeviceID == Self.hostID)
        #expect(row.terminals.map(\.id.rawValue) == [Self.surfaceID])
    }

    @Test("Typing goes to the host, never to the Mac input pipeline")
    func inputRoutesToTheHost() {
        let host = RecordingHost(hostID: Self.hostID, surfaceID: Self.surfaceID)
        let composite = Self.composite(with: host)

        composite.sendTerminalRawInput(Data("ls\r".utf8), surfaceID: Self.surfaceID)

        #expect(host.sentInput == ["ls\r"])
        // The Mac pipeline models an RPC round trip: had the keystroke entered
        // it, this surface would carry an in-flight send operation. Staying
        // idle is the evidence it never did.
        #expect(composite.terminalSendStatus(forTerminalID: Self.surfaceID) == .idle)
    }

    @Test("A foreign surface is left to the Mac pipeline")
    func foreignSurfaceIsNotClaimed() {
        let host = RecordingHost(hostID: Self.hostID, surfaceID: Self.surfaceID)
        let composite = Self.composite(with: host)

        composite.sendTerminalRawInput(Data("ls\r".utf8), surfaceID: "term-mac")

        #expect(host.sentInput.isEmpty)
    }

    @Test("A repaint request is answered by the host")
    func replayRoutesToTheHost() {
        let host = RecordingHost(hostID: Self.hostID, surfaceID: Self.surfaceID)
        let composite = Self.composite(with: host)

        composite.requestTerminalReplay(surfaceID: Self.surfaceID, trigger: .coldAttach)

        #expect(host.replayRequests == [Self.surfaceID])
    }

    @Test("The composer is available without a Mac RPC client")
    func composerIsAvailable() {
        let host = RecordingHost(hostID: Self.hostID, surfaceID: Self.surfaceID)
        let composite = Self.composite(with: host)
        let row = try! #require(composite.workspaces.first)

        #expect(composite.canSendTerminalInput(to: row.id))
    }

    @Test("Hiding a host withdraws its workspaces, and a republish does not undo it")
    func hidingWithdrawsRows() {
        let host = RecordingHost(hostID: Self.hostID, surfaceID: Self.surfaceID)
        let composite = Self.composite(with: host)

        composite.setExternalHost(Self.hostID, hidden: true)
        #expect(composite.workspaces.isEmpty)

        // The host polls on its own schedule; its next publish must not bring
        // the rows back, which is why visibility filters the derivation
        // instead of deleting the entry.
        composite.applyExternalHostWorkspaceState(Self.state(workspaceName: "api renamed"))
        #expect(composite.workspaces.isEmpty)

        composite.setExternalHost(Self.hostID, hidden: false)
        #expect(composite.workspaces.count == 1)
        #expect(composite.workspaces.first?.name == "api renamed")
    }

    @Test("Hiding the open host clears the selection instead of silently swapping it")
    func hidingTheOpenHostClearsSelection() {
        let host = RecordingHost(hostID: Self.hostID, surfaceID: Self.surfaceID)
        let composite = Self.composite(with: host)
        // A second host stays visible, so a fallback would have somewhere to
        // land and the swap would go unnoticed.
        let otherHostID = "cmux-cloud\u{1D}vm-2"
        let other = RecordingHost(hostID: otherHostID, surfaceID: "cmux-cloud\u{1D}vm-2\u{1D}term-9")
        composite.registerExternalHostSource(other)
        composite.applyExternalHostWorkspaceState(
            MacWorkspaceState(
                macDeviceID: otherHostID,
                displayName: "other",
                workspaces: [
                    MobileWorkspacePreview(
                        id: MobileWorkspacePreview.ID(rawValue: "cmux-cloud\u{1D}vm-2\u{1D}ws-9"),
                        macDeviceID: otherHostID,
                        name: "other work",
                        terminals: []
                    )
                ],
                status: .connected,
                workspaceSnapshotIsAuthoritative: true
            )
        )
        let openRow = try! #require(composite.workspaces.first { $0.macDeviceID == Self.hostID })
        composite.selectedWorkspaceID = openRow.id

        composite.setExternalHost(Self.hostID, hidden: true)

        #expect(composite.selectedWorkspaceID == nil)
        #expect(!composite.workspaces.contains { $0.macDeviceID == Self.hostID })
    }

    @Test("Hiding a host the user is not in leaves the selection alone")
    func hidingAnotherHostKeepsSelection() {
        let host = RecordingHost(hostID: Self.hostID, surfaceID: Self.surfaceID)
        let composite = Self.composite(with: host)
        let openRow = try! #require(composite.workspaces.first)
        composite.selectedWorkspaceID = openRow.id

        composite.setExternalHost("cmux-cloud\u{1D}vm-absent", hidden: true)

        #expect(composite.selectedWorkspaceID == openRow.id)
    }

    @Test("The Computers screen sees the host, its liveness and its count")
    func summariesDescribeTheHost() {
        let host = RecordingHost(hostID: Self.hostID, surfaceID: Self.surfaceID)
        let composite = Self.composite(with: host)

        let summary = try! #require(composite.externalHostSummaries.first)
        #expect(summary.hostID == Self.hostID)
        #expect(summary.displayName == "sleepy-teal-otter")
        #expect(summary.status == .connected)
        #expect(summary.workspaceCount == 1)
        #expect(!summary.isHidden)

        composite.setExternalHost(Self.hostID, hidden: true)
        #expect(composite.externalHostSummaries.first?.isHidden == true)
    }

    @Test("A stored Mac redialing with no rows does not claim a list a Cloud machine serves")
    func macRecoveryWithoutRowsYieldsTheHeader() {
        let host = RecordingHost(hostID: Self.hostID, surfaceID: Self.surfaceID)
        let composite = Self.composite(with: host)
        composite.isRecoveringConnection = true

        #expect(!composite.workspaceListShowsForegroundRecovery)
        #expect(composite.workspaceListConnectionStatus == .connected)
    }

    @Test("With nothing else live, a Mac's recovery keeps the header")
    func macRecoveryKeepsTheHeaderWhenNothingElseServes() {
        let host = RecordingHost(hostID: Self.hostID, surfaceID: Self.surfaceID)
        let composite = Self.composite(with: host)
        var reconnecting = Self.state()
        reconnecting.status = .reconnecting
        composite.applyExternalHostWorkspaceState(reconnecting)
        composite.isRecoveringConnection = true

        #expect(composite.workspaceListShowsForegroundRecovery)
        #expect(MobileShellComposite(workspaces: []).workspaceListShowsForegroundRecovery)
    }

    @Test("A Mac with rows on screen keeps its recovery in the header beside a Cloud machine")
    func macWithRowsKeepsItsRecovery() {
        let host = RecordingHost(hostID: Self.hostID, surfaceID: Self.surfaceID)
        let composite = Self.composite(with: host)
        composite.workspacesByMac[.anonymousForeground] = MacWorkspaceState(
            macDeviceID: MacPairingKey.anonymousForeground.canonicalMacDeviceID,
            workspaces: [
                MobileWorkspacePreview(
                    id: MobileWorkspacePreview.ID(rawValue: "mac-ws"),
                    name: "mac work",
                    terminals: []
                )
            ],
            status: .reconnecting,
            workspaceSnapshotIsAuthoritative: false
        )
        composite.isRecoveringConnection = true

        #expect(composite.workspaceListShowsForegroundRecovery)
    }

    @Test("A hidden Cloud machine does not make the visible list look healthy")
    func hiddenHostDoesNotHideRecovery() {
        let host = RecordingHost(hostID: Self.hostID, surfaceID: Self.surfaceID)
        let composite = Self.composite(with: host)
        composite.setExternalHost(Self.hostID, hidden: true)
        composite.isRecoveringConnection = true

        #expect(composite.workspaceListShowsForegroundRecovery)
        #expect(composite.workspaceListConnectionStatus == composite.macConnectionStatus)
    }

    @Test("Unregistering a source disowns its surfaces")
    func unregisterDisowns() {
        let host = RecordingHost(hostID: Self.hostID, surfaceID: Self.surfaceID)
        let composite = Self.composite(with: host)

        composite.unregisterExternalHostSource(host)
        composite.sendTerminalRawInput(Data("ls\r".utf8), surfaceID: Self.surfaceID)

        #expect(host.sentInput.isEmpty)
    }
}
