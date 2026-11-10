public import AppKit
public import CmuxNextControl
import CmuxNextDaemonService
public import CmuxNextPages
import CmuxNextServer
import CmuxNextSettings
import Foundation

/// App health's popover entry. Its triggers are the sidebar footer's line (``AppHealthIndicatorView``)
/// and the "Restoring sessions…" card's Details; each calls ``open(over:)``, which shows the React popover (`cmux-page://cmux.server-cards/#/app-health`,
/// webviews/src/app-health) in a floating card panel, as the server's Health card opens. The
/// state any trigger needs is ``AppHealth/snapshot`` and ``AppHealth/headline``.
@MainActor
public final class AppHealthPopover {
    private let health: AppHealth
    private let overlayProcess: PageOverlayProcess?
    private var panel: WebCardPanel?

    public init(health: AppHealth, overlayProcess: PageOverlayProcess?) {
        self.health = health
        self.overlayProcess = overlayProcess
    }

    /// Opens the popover over `window` (the person's click on a trigger).
    public func open(over window: NSWindow?) {
        if panel == nil {
            panel = WebCardPanel(descriptor: .serverCards, cards: [AppHealthCard(health: health)], overlayProcess: overlayProcess)
        }
        panel?.present(card: AppHealthCard.route, over: window, takeKeys: true)
    }
}

/// The app health popover's ops on the server card page (`#/app-health`, webviews/src/app-health/types.ts):
/// stream `cmux.app.health.snapshot` (the current snapshot, then each changed one; the newest wins)
/// and `cmux.app.health.repair_now {id}` (the person's click only).
@MainActor
final class AppHealthCard: WebCard {
    static let route = "app-health"
    static let snapshotStream = "cmux.app.health.snapshot"
    static let repairNowOp = "cmux.app.health.repair_now"

    let card = AppHealthCard.route
    let prefix = "cmux.app.health."
    weak var host: WebCardPanel?
    private let health: AppHealth

    init(health: AppHealth) {
        self.health = health
    }

    func opened(again: Bool) {}

    func closed() {}

    func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        guard op == Self.repairNowOp else { throw PageError.unknownOp(op) }
        guard context.userGesture else { throw PageError(code: PageNativeOp.userOnlyCode, message: RefusalStrings.personOnlyFromPage) }
        guard let id = params["id"]?.stringValue, !id.isEmpty else { throw PageError.invalidParams("id is required") }
        health.repairNow(id: id)
        return .null
    }

    func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                   onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
        guard stream == Self.snapshotStream else { throw PageError.unknownOp(stream) }
        let (snapshots, continuation) = AsyncStream<JSONValue>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let health = health
        let token = health.subscribe { continuation.yield($0) }
        // task-owner: the page's subscription; ends when it is cancelled (unsubscribe, page close).
        let pump = Task {
            for await snapshot in snapshots { onEvent(snapshot) }
        }
        return PageSubscription {
            health.unsubscribe(token)
            continuation.finish()
            pump.cancel()
        }
    }
}

/// App health's native words: the part labels the app gives the Rust model (the popover's own words
/// are the web page's).
struct AppHealthStrings {
    static var sessionDaemon: String { String(localized: "appHealth.part.sessionDaemon", defaultValue: "Session service", table: "AppHealth", bundle: .module) }
    static var connection: String {
        String(localized: "appHealth.part.acpmux", defaultValue: "Connection to the session service", table: "AppHealth", bundle: .module)
    }
    static var pageHost: String { String(localized: "appHealth.part.pageHost", defaultValue: "Page server", table: "AppHealth", bundle: .module) }

    /// The footer line, as the web's indicator says it: "Session service: Not responding", or with no
    /// unhealthy part the newest queued action ("Reconnecting; will close Background task when back").
    static func line(_ headline: AppHealth.Headline) -> String? {
        if let label = headline.label, let state = headline.state.flatMap(Self.state) {
            return String(format: String(localized: "appHealth.line", defaultValue: "%1$@: %2$@", table: "AppHealth", bundle: .module), label, state)
        }
        return headline.pending.map {
            String(format: String(localized: "appHealth.pending", defaultValue: "Reconnecting; will %@ when back", table: "AppHealth", bundle: .module), $0)
        }
    }

    static func state(_ state: AppHealth.State) -> String? {
        switch state {
        case .healthy: nil
        case .slow: String(localized: "appHealth.state.slow", defaultValue: "Slow", table: "AppHealth", bundle: .module)
        case .repairing: String(localized: "appHealth.state.repairing", defaultValue: "Repairing", table: "AppHealth", bundle: .module)
        case .stuck: String(localized: "appHealth.state.stuck", defaultValue: "Not responding", table: "AppHealth", bundle: .module)
        case .failed: String(localized: "appHealth.state.failed", defaultValue: "Needs a repair", table: "AppHealth", bundle: .module)
        }
    }
}
