/// The sign-in and machine-list state that decides whether a saved Cloud workspace is gone
/// (P-AUSTIN B7b): the app reads it from its Cloud service, and the window registry's `isDead` asks
/// it whether a machine left the account and whether every Cloud machine list has settled.
///
/// Only the list of the user and team signed in now (`hasLoadedCurrentMachines`) says anything: after
/// a team switch the user stays signed in, and the store keeps the previous team's list until the new
/// team's list lands. The new team's machines are not in that old list.
public struct CloudMachineListFacts: Sendable, Hashable {
    /// Whether a person is signed in to cmux Cloud.
    public var isSignedIn: Bool
    /// Whether the saved sign-in is being restored (launch).
    public var isRestoring: Bool
    /// Whether the store holds a list the server answered for the user and team signed in now.
    public var hasLoadedCurrentMachines: Bool

    /// - Parameters:
    ///   - isSignedIn: Whether a person is signed in.
    ///   - isRestoring: Whether the saved sign-in is being restored.
    ///   - hasLoadedCurrentMachines: Whether the loaded list is this user's and team's.
    public init(isSignedIn: Bool, isRestoring: Bool, hasLoadedCurrentMachines: Bool) {
        self.isSignedIn = isSignedIn
        self.isRestoring = isRestoring
        self.hasLoadedCurrentMachines = hasLoadedCurrentMachines
    }

    /// The facts from the store's raw list state, so the rule that the list must be the current
    /// account's lives in one place (cmux-cloud-machine `list_facts.rs`).
    /// - Parameters:
    ///   - isSignedIn: Whether a person is signed in.
    ///   - isRestoring: Whether the saved sign-in is being restored.
    ///   - hasLoadedMachines: Whether the store holds a list the server answered, for any account.
    ///   - loadedFor: Whom that list is for (`[user id, team id]` when it landed); nil before any list.
    ///   - account: Whom the person is signed in as now (`[user id, team id]`).
    public init(isSignedIn: Bool, isRestoring: Bool, hasLoadedMachines: Bool, loadedFor: [String?]?,
                account: [String?]) {
        self.init(isSignedIn: isSignedIn, isRestoring: isRestoring, hasLoadedCurrentMachines: false)
        let read = Self.read(Inputs(isSignedIn: isSignedIn, isRestoring: isRestoring, hasLoadedMachines: hasLoadedMachines,
                                    loadedFor: loadedFor, account: account))
        hasLoadedCurrentMachines = read?.hasLoadedCurrentMachines ?? false
    }

    private struct Inputs: Encodable {
        var isSignedIn: Bool, isRestoring: Bool
        var hasLoadedMachines = false, loadedFor: [String?]?, account: [String?] = []
        var hasLoadedCurrentMachines: Bool?
    }

    private struct Read: Decodable {
        var hasLoadedCurrentMachines: Bool
        var accountListLoaded: Bool
        var settled: String
    }

    private static func read(_ inputs: Inputs) -> Read? {
        CloudMachineRules().call("cloud_machine_list_facts", inputs, as: Read.self)
    }

    private var facts: Read? {
        Self.read(Inputs(isSignedIn: isSignedIn, isRestoring: isRestoring, hasLoadedCurrentMachines: hasLoadedCurrentMachines))
    }

    /// The signed-in account's own machine list has loaded: a machine it does not list left the account.
    public var accountListLoaded: Bool { facts?.accountListLoaded ?? false }

    /// Whether a saved workspace's Cloud machine, which this run has no daemon for, left the account.
    /// `listed`: the machine registry has the machine, its feature on or off. Signed out, Cloud off, the
    /// list not loaded (or the previous team's), or the machine listed: it is only not connected.
    public func machineLeft(listed: Bool) -> Bool {
        !listed && accountListLoaded
    }

    /// Whether every Cloud machine that could still report workspaces has reported: signed out and not
    /// restoring, yes; otherwise the current account's list must have loaded and `machinesLoaded` hold.
    public func settled(machinesLoaded: () -> Bool) -> Bool {
        switch facts?.settled {
        case "yes": true
        case "ifMachinesLoaded": machinesLoaded()
        default: false
        }
    }
}
