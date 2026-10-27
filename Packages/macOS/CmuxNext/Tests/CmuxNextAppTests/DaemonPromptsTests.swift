import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextDesign
import Foundation
import Testing

/// The daemon's prompts subscribe to the store's side events in the turn they start, with no post
/// between: side events keep no backlog, and the first events of a trusted subscribe are the
/// daemon's pending pairings (cmd_subscribe.rs). `AppServices.startLocalDaemon` starts them before
/// the daemon, so a pairing the daemon replays on its first connect shows its dialog.
@MainActor @Suite(.serialized)
struct DaemonPromptsTests {
    private final class SilentDialogHost: CmuxDialogHosting {
        func show(_ dialog: CmuxDialogView, in scope: CmuxDialogScope, scopeGone: @escaping () -> Void) {}
        func hide(_ dialog: CmuxDialogView) {}
    }

    private static func pairing(_ name: String, request: String) -> DaemonEvent {
        .unknown(name: name, payload: .object(["request_id": .string(request), "code": .string("123456"), "peer": .string("chrome-extension://cmux")]))
    }

    @Test func aPairingDeliveredInTheTurnThePromptsStartShowsItsDialog() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let center = CmuxDialogCenter(host: SilentDialogHost())
        let prompts = DaemonPrompts.start(services, center: center)
        defer {
            prompts.clipboardReads.stop()
            prompts.pairings.stop()
        }
        // The replay of a trusted subscribe, before any main turn or startup post runs.
        services.daemon.store.sideEvents.deliver(Self.pairing("pairing-requested", request: "7"))
        #expect(center.records.count == 1, "the replayed pairing reached no handler")
        services.daemon.store.sideEvents.deliver(Self.pairing("pairing-resolved", request: "7"))
        #expect(center.records.isEmpty, "the resolved pairing left its dialog open")
    }
}
