import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileRPC
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

/// Behavior tests for the QR scan journey's failure surface on the composite
/// itself (preview mode, no transport): every distinct way a scanned code can
/// be bad must surface its own actionable message through the shared
/// ``MobileShellComposite/connectionError`` surface, and a scan performed while
/// a live session exists must never tear that session down.
@MainActor
@Suite struct MobilePairingScanBehaviorTests {
    private func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func attachURLString(for ticket: CmxAttachTicket) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let payload = base64URLEncode(try encoder.encode(ticket))
        return "cmux-ios://attach?v=1&payload=\(payload)"
    }

    /// A signed-in preview store connected to "Test Mac" through a real attach
    /// ticket (preview mode connects without a transport but still records the
    /// active ticket), mirroring the state a user is in when they open the
    /// Switch Mac sheet and scan another code.
    private func connectedPreviewStore() async throws -> (MobileShellComposite, CmxAttachTicket) {
        let route = try CmxAttachRoute(
            id: "debug_loopback",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 56577)
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "live-workspace",
            terminalID: "live-terminal",
            macDeviceID: "test-mac",
            macDisplayName: "Test Mac",
            routes: [route],
            expiresAt: Date().addingTimeInterval(60)
        )
        let store = MobileShellComposite.preview()
        store.signIn()
        let didConnect = await store.connectPairingURL(try attachURLString(for: ticket))
        #expect(didConnect)
        #expect(store.connectionState == .connected)
        return (store, ticket)
    }

    // MARK: - Decode failures map to distinct walk-through messages

    @Test func expiredAttachPayloadShowsExpiredCodeMessage() async throws {
        // CmxAttachTicket's memberwise init validates, so an expired ticket can
        // only come in over the wire: hand-roll the JSON the Mac would have
        // minted yesterday.
        let json = """
        {
          "version": 1,
          "workspaceID": "live-workspace",
          "macDeviceID": "test-mac",
          "routes": [{"id": "tailscale", "kind": "tailscale", "endpoint": {"type": "host_port", "host": "100.71.210.41", "port": 58465}, "priority": 0}],
          "expiresAt": "1970-01-01T00:00:01Z"
        }
        """
        let store = MobileShellComposite.preview()
        store.signIn()

        let didConnect = await store.connectPairingURL(
            "cmux-ios://attach?v=1&payload=\(base64URLEncode(Data(json.utf8)))"
        )

        #expect(!didConnect)
        #expect(store.connectionState == .disconnected)
        #expect(store.connectionError == "This code expired. On your Mac, click Refresh Code in the pairing window, then scan the new code.")
    }

    @Test func newerFormatAttachPayloadAsksUserToUpdateThisApp() async throws {
        // A compact short-key payload (top-level "v", the grammar newer Macs put
        // in the pairing QR, https://github.com/manaflow-ai/cmux/pull/5727) that
        // this app cannot decode must loudly say "update this app". Rescanning
        // the same code can never help, so "invalid code" would strand the user.
        let json = """
        {"v":2,"m":"test-mac","n":"Test Mac","e":4102444800,"r":[["ts","100.71.210.41",58465]]}
        """
        let store = MobileShellComposite.preview()
        store.signIn()

        let didConnect = await store.connectPairingURL(
            "cmux-ios://attach?payload=\(base64URLEncode(Data(json.utf8)))"
        )

        #expect(!didConnect)
        #expect(store.connectionState == .disconnected)
        #expect(store.connectionError == "This code is from a newer version of cmux. Update cmux on this device, then scan a fresh code.")
    }

    @Test func newerVersionPairPayloadAsksUserToUpdateThisApp() async throws {
        // Same loud "update this app" contract for the pair grammar when the Mac
        // minted a payload version this app does not speak yet.
        let json = """
        {
          "version": 2,
          "mac_device_id": "test-mac",
          "host": "100.71.210.41",
          "port": 58465,
          "expires_at": "2099-01-01T00:00:01Z",
          "transport": "tailscale"
        }
        """
        let store = MobileShellComposite.preview()
        store.signIn()

        let didConnect = await store.connectPairingURL(
            "cmux-ios://pair?v=2&payload=\(base64URLEncode(Data(json.utf8)))"
        )

        #expect(!didConnect)
        #expect(store.connectionState == .disconnected)
        #expect(store.connectionError == "This code is from a newer version of cmux. Update cmux on this device, then scan a fresh code.")
    }

    @Test func garbagePayloadStillShowsActionableInvalidCodeMessage() async {
        let store = MobileShellComposite.preview()
        store.signIn()

        let didConnect = await store.connectPairingURL("cmux-ios://attach?payload=not-base64")

        #expect(!didConnect)
        #expect(store.connectionError == "This pairing code couldn't be read. On your Mac, click Refresh Code in the pairing window and scan the new code.")
    }

    // MARK: - Scans while connected never tear down the live session

    @Test func unreadableScanWhileConnectedKeepsLiveConnection() async throws {
        let (store, ticket) = try await connectedPreviewStore()

        // Scanning a bad code while connected (e.g. from the Switch Mac sheet)
        // must surface the failure without tearing down the live session. The
        // result is the dedicated `.rejected` (not `.failed`) so the root
        // attach-auth gate does not clear attach-ticket authentication.
        let result = await store.connectPairingURLResult("cmux-ios://attach?payload=not-base64")

        #expect(result == .rejected)
        #expect(store.connectionState == .connected)
        #expect(store.activeTicket?.macDeviceID == ticket.macDeviceID)
        // The outcome is reported as an informational notice (the live session
        // is fine), not through the disconnected-pairing error surface.
        #expect(store.pairingNotice?.isEmpty == false)
        #expect(store.connectionError == nil)
    }

    @Test func rescanningTheConnectedMacShowsAlreadyPairedNotice() async throws {
        let (store, ticket) = try await connectedPreviewStore()

        let result = await store.connectPairingURLResult(try attachURLString(for: ticket))

        #expect(result == .connected)
        #expect(store.connectionState == .connected)
        #expect(store.activeTicket?.macDeviceID == ticket.macDeviceID)
        #expect(store.pairingNotice == "Already connected to Test Mac. This Mac is paired on this device, so there's no need to scan its code again.")
        #expect(store.connectionError == nil)

        store.dismissPairingNotice()
        #expect(store.pairingNotice == nil)
    }

    @Test func scanningADifferentMacWhileConnectedStillRepairs() async throws {
        let (store, _) = try await connectedPreviewStore()
        let otherRoute = try CmxAttachRoute(
            id: "debug_loopback",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 56578)
        )
        let otherTicket = try CmxAttachTicket(
            workspaceID: "other-workspace",
            terminalID: nil,
            macDeviceID: "other-mac",
            macDisplayName: "Other Mac",
            routes: [otherRoute],
            expiresAt: Date().addingTimeInterval(60)
        )

        let result = await store.connectPairingURLResult(try attachURLString(for: otherTicket))

        #expect(result == .connected)
        #expect(store.activeTicket?.macDeviceID == "other-mac")
        #expect(store.pairingNotice == nil)
    }

    // MARK: - Post-pair store failure surfaces a notice

    @Test func pairedMacStoreFailureShowsPairedButNotSavedNotice() async throws {
        let route = try CmxAttachRoute(
            id: "tailscale",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.71.210.41", port: 58465)
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "live-workspace",
            terminalID: nil,
            macDeviceID: "test-mac",
            macDisplayName: "Test Mac",
            routes: [route],
            expiresAt: Date().addingTimeInterval(60)
        )
        let store = MobileShellComposite(
            pairedMacStore: FailingPairedMacStore(),
            pairingHintDefaults: UserDefaults(suiteName: "MobilePairingScanBehaviorTests-\(UUID().uuidString)")!
        )
        store.signIn()

        await store.persistPairedMacFromTicket(ticket)

        // The session is up but the pairing didn't save: the user is told now,
        // with the consequence and the recovery, instead of a silent log line.
        #expect(store.pairingNotice == "Paired, but this device couldn't save the pairing. If cmux doesn't reconnect by itself next time, scan the code from your Mac again.")
        #expect(store.hasKnownPairedMac == false)
    }
}

/// In-memory paired-Mac store whose writes always fail, driving the
/// post-pair save-failure notice path.
private struct FailingPairedMacStore: MobilePairedMacStoring {
    struct WriteFailed: Error {}

    func upsert(
        macDeviceID: String,
        displayName: String?,
        routes: [CmxAttachRoute],
        markActive: Bool,
        stackUserID: String?,
        now: Date
    ) async throws {
        throw WriteFailed()
    }

    func loadAll(stackUserID: String?) async throws -> [MobilePairedMac] { [] }
    func activeMac(stackUserID: String?) async throws -> MobilePairedMac? { nil }
    func setActive(macDeviceID: String) async throws { throw WriteFailed() }
    func remove(macDeviceID: String) async throws { throw WriteFailed() }
    func removeAll() async throws { throw WriteFailed() }
}

/// Pure tests for the scan gate that decides what a scanned code may do while
/// a live session exists (the decode-before-attempt guard).
@MainActor
@Suite struct MobilePairingScanGateTests {
    private func ticket(macDeviceID: String, name: String? = "Test Mac") throws -> CmxAttachTicket {
        try CmxAttachTicket(
            workspaceID: "ws",
            terminalID: nil,
            macDeviceID: macDeviceID,
            macDisplayName: name,
            routes: [
                try CmxAttachRoute(
                    id: "tailscale",
                    kind: .tailscale,
                    endpoint: .hostPort(host: "100.71.210.41", port: 58465)
                ),
            ],
            expiresAt: Date().addingTimeInterval(60)
        )
    }

    @Test func disconnectedAlwaysProceeds() throws {
        struct SomeError: Error {}
        #expect(MobilePairingScanGate.disposition(
            decodeResult: .success(try ticket(macDeviceID: "mac-1")),
            isConnected: false,
            activeMacDeviceID: nil
        ) == .proceed)
        #expect(MobilePairingScanGate.disposition(
            decodeResult: .failure(SomeError()),
            isConnected: false,
            activeMacDeviceID: nil
        ) == .proceed)
    }

    @Test func sameMacWhileConnectedIsAlreadyConnected() throws {
        let disposition = MobilePairingScanGate.disposition(
            decodeResult: .success(try ticket(macDeviceID: "mac-1", name: "Studio")),
            isConnected: true,
            activeMacDeviceID: "mac-1"
        )
        #expect(disposition == .alreadyConnected(macName: "Studio"))
    }

    @Test func differentMacWhileConnectedProceeds() throws {
        let disposition = MobilePairingScanGate.disposition(
            decodeResult: .success(try ticket(macDeviceID: "mac-2")),
            isConnected: true,
            activeMacDeviceID: "mac-1"
        )
        #expect(disposition == .proceed)
    }

    @Test func undecodableWhileConnectedRejectsWithClassifiedCategory() {
        let disposition = MobilePairingScanGate.disposition(
            decodeResult: .failure(MobileSyncPairingPayloadError.expired),
            isConnected: true,
            activeMacDeviceID: "mac-1"
        )
        #expect(disposition == .rejectKeepingConnection(.ticketExpired))
    }
}
