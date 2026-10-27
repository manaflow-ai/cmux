/// A kind of work inside a ``BlockingLane`` with its own limit of running items, below the lane's width.
///
/// One kind of system call can hang for its own timeout (a resolver up to 30 s) while every other kind still
/// answers at once. Its own cap keeps a hung kind from taking every slot of the lane, and a capped item never
/// takes a reserved slot, so a hung DNS server never holds keychain or Accessibility work. Chrome gives its
/// system DNS tasks a pool of their own instead (net/dns/host_resolver_manager.cc); here they share the system lane.
enum LaneCap: Hashable, Sendable {
    /// Host name resolution (`getaddrinfo`, ``BackgroundWork/resolveHost(_:shutdown:fileID:line:_:)``):
    /// at most ``BackgroundWork/hostResolutionCap`` at once on ``BlockingLane/system``.
    case hostResolution
}
