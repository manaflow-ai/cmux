import AppKit
@testable import CmuxNextApps
import Testing

/// Lawrence 2026-11-12 (9:13 PM screenshot: a "Needs a newer cmux" card under the pins): "get rid of
/// “Needs a newer cmux”". A build whose daemon cannot run apps (no app host beside it), or a Mac where
/// a policy turned apps off, draws no app section in the sidebar: no card and no gap where it was. A
/// newer cmux would not change it, and the sidebar offers nothing to do about it; the Apps page says
/// why. A daemon that is only not connected yet still shows the section with its reason, which goes
/// away when it connects.
@MainActor @Suite(.serialized) struct AppSectionUnavailableTests {
    private final class Transport: AppsTransport {
        var availability: AppsAvailability
        var onEvent: ((AppsTransportEvent) -> Void)?
        var mounted: [String] = []

        init(_ availability: AppsAvailability) { self.availability = availability }

        func start() {}
        func list() async throws(AppsTransportError) -> AppsListReply {
            throw AppsTransportError(message: "unavailable")
        }
        func sessionInfoPanels() async throws(AppsTransportError) -> [AppSessionInfoPanel] { [] }
        func set(app: String, change: AppChange, origin: AppOrigin, idempotencyKey: String) async throws(AppsTransportError) -> AppRecord {
            throw AppsTransportError(message: "unused")
        }
        func mount(app: String, interface: String, mountID: String, context: AppJSON) async throws(AppsTransportError) {
            mounted.append(mountID)
        }
        func unmount(mountID: String) async throws(AppsTransportError) {}
        func dispatch(mountID: String, node: String, event: String, payload: AppJSON) async throws(AppsTransportError) {}
        func run(app: String, op: String, args: AppJSON, origin: AppOrigin, idempotencyKey: String) async throws(AppsTransportError) -> AppJSON {
            .null
        }
        func logs(app: String, follow: Bool) async throws(AppsTransportError) -> [AppLogLine] { [] }
    }

    static let contribution = "local/customize#main"

    private static func provider(_ availability: AppsAvailability) -> (Transport, AppsClient, AppSectionProvider) {
        let transport = Transport(availability)
        let client = AppsClient(transport: transport)
        client.start()
        return (transport, client, AppSectionProvider(client: client, isPresented: { _ in true }))
    }

    @Test(arguments: [AppsUnavailableReason.needsNewerDaemon, .turnedOff("Turned off by your administrator")])
    func aSectionDrawsNothingWhileAppsCannotRunHere(_ reason: AppsUnavailableReason) {
        let (_, _, provider) = Self.provider(.unavailable(reason))
        #expect(provider.makeView(for: Self.contribution) == nil, "the sidebar draws a \"\(reason.text)\" card")
        #expect(provider.preferredHeight(for: Self.contribution, width: 260) == 0)
    }

    @Test func aSectionShownWhileConnectingGoesAwayWhenTheDaemonCannotRunApps() {
        let (transport, client, provider) = Self.provider(.unavailable(.notConnected))
        // Not connected yet: the section mounts and says why it is empty.
        #expect(provider.makeView(for: Self.contribution) != nil)
        transport.availability = .unavailable(.needsNewerDaemon)
        transport.onEvent?(.availability(.unavailable(.needsNewerDaemon)))
        #expect(client.unavailableReason == .needsNewerDaemon)
        #expect(provider.makeView(for: Self.contribution) == nil, "the section's card stays after the daemon answered without apps")
        #expect(provider.preferredHeight(for: Self.contribution, width: 260) == 0)
    }
}
