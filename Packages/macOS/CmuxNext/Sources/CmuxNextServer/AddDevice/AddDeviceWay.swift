/// The three ways into the Add Device card (plans/cmux-next/add-device-DESIGN.md 2.3).
public nonisolated enum AddDeviceWay: String, CaseIterable, Equatable, Sendable {
    /// A computer the network already knows: one click runs the enroll (Add Machine's steps).
    case network
    /// The new computer shows a code and four words: type the code, check the words, approve
    /// (Add Server's flow, the cloud pairing).
    case code
    /// Nothing is set up on it yet: one line to run there, then it shows a code (way ``code``).
    case newDevice
}
