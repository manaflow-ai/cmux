/// Opens a sign-in's tab: ephemeral sessions in a non-persistent profile.
/// The tab reports its navigations and its close to `broker`. Nil when no
/// tab can open.
@MainActor
package protocol WebAuthSessionOpening: AnyObject {
    func open(_ request: any WebAuthSessionRequest, broker: WebAuthSessionBroker) -> (any WebAuthSessionSurface)?
}
