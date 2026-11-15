public import Foundation

/// Link handlers (`cmux.opener/1`): a link the person clicks goes first to the app whose opener
/// matches it. The daemon picks the app (cmux-tui-core `apps/openers.rs`); the client only asks,
/// and only while some visible app implements an opener, so a click costs no round trip otherwise.
/// The list `apps-changed` brings back decides that, so a saved manifest that adds or drops an
/// opener changes the next click with no relaunch.
extension AppsClient {
    public static let openerInterface = "cmux.opener/1"

    /// Some installed, enabled and visible app implements `cmux.opener/1`.
    public var hasLinkOpeners: Bool {
        isListed && apps.contains { app in
            app.isVisible && app.manifest.implementations.contains { $0.interface == Self.openerInterface }
        }
    }

    /// Offers `url`, clicked by the person, to the matching app's opener. Returns the app that
    /// opened it; nil when none did (no opener matches, the supervisor is unreachable, or the
    /// opener failed), and the caller opens the link itself.
    public func openLink(_ url: URL) async -> String? {
        guard hasLinkOpeners else { return nil }
        do throws(AppsTransportError) {
            let answer = try await transport.openLink(url.absoluteString, origin: .user)
            guard answer["handled"]?.boolValue == true else { return nil }
            return answer["app"]?.stringValue
        } catch {
            return nil
        }
    }
}
