import Foundation

/// Serves other apps' sign-ins while cmux is the default browser: each
/// request opens in a tab and ends exactly once, with its callback URL (the
/// tab closes) or cancelled (the person closed the tab). One owner for the
/// pending sessions; the shim and the tab only report events here.
///
/// The system's begin and cancel arrive in the order macOS made them
/// (``WebAuthSessionHandler`` sends both through one ordered stream), so a
/// request the broker does not hold has ended or never opened: the broker
/// keeps nothing for it.
@MainActor
package final class WebAuthSessionBroker {
    struct Session {
        let request: any WebAuthSessionRequest
        var surface: (any WebAuthSessionSurface)?
    }

    private let opener: any WebAuthSessionOpening
    private(set) var pending: [UUID: Session] = [:]

    package init(opener: any WebAuthSessionOpening) {
        self.opener = opener
    }

    /// The system asks cmux to run `request`. Only a web start page opens.
    func begin(_ request: any WebAuthSessionRequest) {
        guard pending[request.id] == nil else { return }
        guard let scheme = request.url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return request.cancel() }
        pending[request.id] = Session(request: request, surface: nil)
        guard let surface = opener.open(request, broker: self) else {
            pending[request.id] = nil
            return request.cancel()
        }
        // The tab may have closed (or matched) while it opened.
        if pending[request.id] != nil { pending[request.id]?.surface = surface }
    }

    /// The session's tab went to `url` (main frame). True when that is the
    /// callback: the session completes with it, its tab closes, and the
    /// caller must not load it.
    @discardableResult
    func navigated(_ id: UUID, to url: URL) -> Bool {
        guard let session = pending[id], session.request.matches(url) else { return false }
        pending[id] = nil
        session.request.complete(with: url)
        session.surface?.close()
        return true
    }

    /// The person closed the session's tab before its callback.
    func surfaceClosed(_ id: UUID) {
        guard let session = pending.removeValue(forKey: id) else { return }
        session.request.cancel()
    }

    /// The system ended the session (the requesting app cancelled it): its
    /// tab closes, and nothing answers the request. A cancel for a session
    /// that already ended (completed, closed, refused or never opened)
    /// changes nothing.
    func systemCancelled(_ id: UUID) {
        guard let session = pending.removeValue(forKey: id) else { return }
        session.surface?.close()
    }
}
