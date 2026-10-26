/// A kind of work inside a ``BlockingLane`` with its own limit of running items, below the lane's width.
///
/// One kind of system call can hang for its own timeout (a resolver up to 30 s) while every other kind still
/// answers at once. Its own cap keeps a hung kind from taking every slot of the lane, so a hung DNS server
/// never holds keychain or Accessibility work. Chrome runs its system DNS tasks through their own
/// `PrioritizedDispatcher` with a limit (`kDefaultMaxSystemTasks`, net/dns/host_resolver_manager.cc).
enum LaneCap: Hashable, Sendable {
    /// Host name resolution (`getaddrinfo`, ``BackgroundWork/runHostResolution(_:shutdown:fileID:line:_:)``):
    /// at most ``BackgroundWork/hostResolutionCap`` at once on ``BlockingLane/system``.
    case hostResolution
}
