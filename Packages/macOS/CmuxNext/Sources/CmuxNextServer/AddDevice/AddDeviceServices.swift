/// What the Add Device card asks of the app, so its flow runs the same in tests with fakes.
public struct AddDeviceServices {
    /// `cmux device list --json`; nil when the CLI is missing or failed.
    public var list: () async -> DeviceListing?
    /// Adds a computer the network knows: the Add Machine card on `address`, started at once.
    public var addComputer: (_ address: String, _ name: String) -> Void
    /// Add Machine with an empty field: a computer reached by a name the network does not list.
    public var addByName: () -> Void
    /// The Add Server card's code field.
    public var enterCode: () -> Void
    /// The app's New Cloud Machine flow (sign-in first when signed out).
    public var newCloudMachine: () -> Void
    public var installTailscale: () -> Void
    public var copy: (String) -> Void
    /// The one-line join's calls, nil while Labs `labs.machineJoin` is off (the way does not show).
    public var machineJoin: () -> MachineJoinService?
    /// Copies a secret line: plain text marked concealed and transient, so clipboard managers skip it.
    public var copyConcealed: (String) -> Void
    /// Shows the Machines sidebar section, where the joined machine is listed (Show in Machines).
    public var showMachines: () -> Void

    public init(list: @escaping () async -> DeviceListing?, addComputer: @escaping (String, String) -> Void,
                addByName: @escaping () -> Void, enterCode: @escaping () -> Void, newCloudMachine: @escaping () -> Void = {},
                copy: @escaping (String) -> Void, installTailscale: @escaping () -> Void = {},
                machineJoin: @escaping () -> MachineJoinService? = { nil },
                copyConcealed: @escaping (String) -> Void = { _ in }, showMachines: @escaping () -> Void = {}) {
        self.list = list
        self.addComputer = addComputer
        self.addByName = addByName
        self.enterCode = enterCode
        self.newCloudMachine = newCloudMachine
        self.copy = copy
        self.installTailscale = installTailscale
        self.machineJoin = machineJoin
        self.copyConcealed = copyConcealed
        self.showMachines = showMachines
    }
}
