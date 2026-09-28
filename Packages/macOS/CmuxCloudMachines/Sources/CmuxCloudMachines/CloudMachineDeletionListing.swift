/// A fence for one fleet read, taken before the read starts.
///
/// A read that started before a delete succeeded may still contain the machine;
/// only a read that started afterwards can retire a confirmed deletion.
public struct CloudMachineDeletionListing: Equatable, Sendable {
    let generation: UInt64
}
