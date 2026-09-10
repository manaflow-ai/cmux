/// A token-owned lease that makes observer delivery stop at token deallocation.
///
/// Models capture this object weakly. Releasing the public observation token
/// therefore disables delivery synchronously, while actor-isolated dictionary
/// cleanup can safely finish in a later main-actor task on older toolchains.
final class ObservationDeliveryLifetime {}
