public import Foundation

extension NotificationCenter {
    /// Stops `observation` (``MainActorObservation/cancel()``).
    ///
    /// Without this overload a ``MainActorObservation`` passed here would go to
    /// `removeObserver(_: Any)`, which takes the token, finds no registered observer and does
    /// nothing: a site that missed the migration would keep observing. Overload resolution picks
    /// this one for a token, so it stops observing; the deprecation warning names the call to
    /// replace with `observation = nil` or `cancel()`.
    @available(*, deprecated, message: "set the MainActorObservation to nil or call cancel()")
    public func removeObserver(_ observation: MainActorObservation) {
        observation.cancel()
    }

    /// Stops `observation` when there is one (the optional form of the overload above).
    @available(*, deprecated, message: "set the MainActorObservation to nil or call cancel()")
    public func removeObserver(_ observation: MainActorObservation?) {
        observation?.cancel()
    }
}
