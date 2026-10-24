import CmuxNextSignposts

/// Where ``LineTransport`` marks each request it waits on: the always-on `daemon.request`
/// interval (``OSDaemonRequestSignposts``) in the app, a recorder in tests.
protocol DaemonRequestSignposting: Sendable {
    /// A request with this `cmd` and client-minted `id` was written; returns what ``end(_:)`` needs.
    func begin(method: String, id: UInt64) -> DaemonRequestSignpost
    /// Its reply (or failure) reached the requester.
    func end(_ signpost: DaemonRequestSignpost)
}

/// One open `daemon.request` interval.
struct DaemonRequestSignpost {
    let id: UInt64
    let interval: SignpostInterval?
}

/// The always-on `daemon.request` interval (``Signposter/daemon``): one `os_signpost` begin and end
/// per request; the message is formatted only while something records.
struct OSDaemonRequestSignposts: DaemonRequestSignposting {
    func begin(method: String, id: UInt64) -> DaemonRequestSignpost {
        DaemonRequestSignpost(id: id, interval: Signposter.daemon.beginDaemonRequest(method: method, id: id))
    }

    func end(_ signpost: DaemonRequestSignpost) {
        if let interval = signpost.interval { Signposter.daemon.end(.daemonRequest, interval) }
    }
}
