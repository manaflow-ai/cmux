/// A transport rejected after synchronous factory admission raced retirement.
///
/// The session transfers this exact disposal task into the shared physical
/// resource registry before releasing its route lease.
struct MobileRPCRejectedTransportDisposal: Error, Sendable {
    let task: Task<Void, Never>
}
