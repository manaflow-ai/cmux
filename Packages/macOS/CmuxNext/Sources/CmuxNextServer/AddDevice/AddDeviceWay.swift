/// The ways into the Add Device card (plans/cmux-next/add-device-DESIGN.md 2.3). ``joinLine`` (the pair
/// code, no ssh) is the default and first; ``network`` (ssh) sits behind Advanced
/// (``AddDeviceModel/ways``, ``AddDeviceModel/advancedWays``).
public nonisolated enum AddDeviceWay: String, CaseIterable, Equatable, Sendable {
    /// A computer the network already knows: one click runs the enroll over ssh (Add Machine's steps).
    /// Behind Advanced whenever ``joinLine`` is offered.
    case network
    /// The new computer shows a code and four words: type the code, check the words, approve
    /// (Add Server's flow, the cloud pairing).
    case code
    /// Nothing is set up on it yet: one line to run there, then it shows a code (way ``code``).
    case newDevice
    /// Any Mac or Linux machine, with no ssh: signed in, a pair code (and QR) the new machine types;
    /// signed out, a single-use line that installs acpmux and joins the person's machines
    /// (``MachineJoinLineModel``). The default way.
    case joinLine
}
