/// The billing control seam (part of the ``ControlCommandContext`` umbrella).
///
/// Billing calls perform authenticated web API requests in the app process so
/// Stack tokens never cross the socket boundary. The methods are `nonisolated`
/// because `billing.*` runs on the socket worker; each app-side witness owns
/// any main-actor/auth hops it needs.
public protocol ControlBillingContext: AnyObject {
    /// Fetches the current signed-in user's live billing plan state.
    nonisolated func controlBillingStatus() -> ControlCallResult

    /// Starts checkout for the requested plan and returns either a URL or a structured billing state.
    nonisolated func controlBillingCheckout(plan: String) -> ControlCallResult

    /// Starts the customer portal flow and returns either a URL or a structured billing state.
    nonisolated func controlBillingPortal() -> ControlCallResult
}
