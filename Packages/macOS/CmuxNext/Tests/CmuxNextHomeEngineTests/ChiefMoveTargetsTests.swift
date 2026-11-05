@testable import CmuxNextHomeEngine
import Testing

/// "Move Chief To…" targets (remote-groups-DESIGN.md slice 6, chief-migration-DESIGN.md 8a): This Mac,
/// every SSH or server remote group, and cmux Cloud while signed in, each mapped to one `--to` value.
/// A paired server moves over SSH like an SSH host; one with no SSH route is listed but greyed out;
/// an offline host is listed but greyed out; a host
/// that is not a remote group is not listed. `--to cloud` is the account's Cloud Chief, not a Cloud
/// VM, so a Cloud VM's group is not a target and Cloud is one entry.
struct ChiefMoveTargetsTests {
    private let hosts: [ChiefMoveTargets.Host] = [
        .init(machineID: "ssh-mini", name: "cmux-mini", kind: .ssh(destination: "lawrence@cmux-mini"), isOnline: true, isRemoteGroup: true),
        .init(machineID: "ssh-gcp", name: "gcp-linux-1", kind: .ssh(destination: "gcp-linux-1"), isOnline: false, isRemoteGroup: true),
        .init(machineID: "ssh-plain", name: "plain", kind: .ssh(destination: "plain"), isOnline: true, isRemoteGroup: false),
        .init(machineID: "srv", name: "brain-box", kind: .server(destination: "brain-box"), isOnline: true, isRemoteGroup: true),
        .init(machineID: "srv-off", name: "brain-off", kind: .server(destination: "me@brain-off"), isOnline: false, isRemoteGroup: true),
        .init(machineID: "srv-noroute", name: "???", kind: .server(destination: nil), isOnline: true, isRemoteGroup: true),
        .init(machineID: "vm-1", name: "a cloud vm", kind: .cloud(staging: false), isOnline: true, isRemoteGroup: true),
    ]

    private var targets: [ChiefMoveTarget] {
        ChiefMoveTargets(localHome: "/Users/me/.cmux/chief/default", hosts: hosts, cloud: .signedIn(staging: false)).targets
    }

    private func target(_ id: String) -> ChiefMoveTarget? { targets.first { $0.machineID == id } }

    @Test func thisMacComesFirstAsALocalHome() {
        #expect(targets.first?.machineID == "local")
        #expect(targets.first?.to == "local:/Users/me/.cmux/chief/default")
        #expect(targets.first?.disabledReason == nil)
    }

    @Test func eachRemoteGroupMapsToOneToValue() {
        #expect(target("ssh-mini")?.to == "ssh:lawrence@cmux-mini")
        #expect(target("ssh-mini")?.disabledReason == nil)
        #expect(target(ChiefMoveTargets.cloudID)?.to == "cloud")
        #expect(target("vm-1") == nil, "a Cloud VM is not where a Cloud Chief lives")
    }

    @Test func cloudFollowsTheAppsAuthAndNeedsASignIn() {
        let staging = ChiefMoveTargets(localHome: "/h", hosts: [], cloud: .signedIn(staging: true)).targets
        #expect(staging.first { $0.machineID == ChiefMoveTargets.cloudID }?.to == "cloud:staging")
        let signedOut = ChiefMoveTargets(localHome: "/h", hosts: [], cloud: .signedOut).targets
        #expect(signedOut.first { $0.machineID == ChiefMoveTargets.cloudID }?.disabledReason == .signInNeeded)
    }

    @Test func offlineTargetsAreListedButGreyedOut() {
        #expect(target("ssh-gcp")?.disabledReason == .offline)
        #expect(target("srv-off")?.disabledReason == .offline)
        #expect(target("srv-off")?.to == "ssh:me@brain-off")
    }

    @Test func aPairedServerMovesOverSSHLikeAnSSHHost() {
        #expect(target("srv")?.to == "ssh:brain-box")
        #expect(target("srv")?.disabledReason == nil)
    }

    @Test func aServerWithNoSSHRouteIsGreyedOut() {
        #expect(target("srv-noroute")?.to == nil)
        #expect(target("srv-noroute")?.disabledReason == .noSSHRoute)
    }

    @Test func aHostThatIsNotARemoteGroupIsNotListed() {
        #expect(target("ssh-plain") == nil)
    }

    /// The Teleport menu lists the same targets, in the same order, with the same `--to` ids
    /// (one list for Cmd-Shift-P, the header chip and the Chief card), each placed so the menu can
    /// check where the Chief runs now; a greyed-out target stays greyed out.
    @Test func theTeleportMenuListsTheSameTargets() {
        let destinations = targets.map(\.teleportDestination)
        #expect(destinations.map(\.id) == targets.map(\.machineID))
        #expect(destinations.first?.place == .thisMac)
        #expect(destinations.first { $0.id == "ssh-mini" }?.place == .host("lawrence@cmux-mini"))
        #expect(destinations.first { $0.id == "srv" }?.place == .host("brain-box"))
        #expect(destinations.first { $0.id == ChiefMoveTargets.cloudID }?.place == .cloud)
        #expect(destinations.first { $0.id == "ssh-gcp" }?.isAvailable == false)
        #expect(destinations.first { $0.id == "srv-noroute" }?.isAvailable == false)
        #expect(destinations.first { $0.id == "ssh-mini" }?.isAvailable == true)
        let menu = ChiefTeleportMenu(location: .host("cmux-mini"), destinations: destinations, phase: .idle)
        #expect(menu.rows.first { $0.id == "ssh-mini" }?.state == .current)
    }
}

/// The steps of one move (chief-migration-DESIGN.md 8a): a dry run whose report the person reads,
/// the move, then `move reach` on the target. A cloud session token goes through a 0600 file, never
/// the command line.
struct ChiefMovePlanTests {
    @Test func sshRunsDryRunThenMoveThenReachOnTheHost() {
        // The target home is the moving home's path under the user's home folder (chief-migration-DESIGN.md 8a).
        let plan = ChiefMovePlan(to: "ssh:cmux-mini", kind: .ssh(destination: "cmux-mini"), sourceHome: "/Users/me/.cmux/chief/dev", targetHome: "~/.cmux/chief/default", tokenFile: nil)
        #expect(plan.dryRun == ["chief", "move", "--to", "ssh:cmux-mini", "--dry-run", "--chief-home", "/Users/me/.cmux/chief/dev"])
        #expect(plan.move == ["chief", "move", "--to", "ssh:cmux-mini", "--chief-home", "/Users/me/.cmux/chief/dev"])
        #expect(plan.reach == .remote(["ssh", "-o", "BatchMode=yes", "cmux-mini", "optchat-chief", "move", "reach", "--home", "~/.cmux/chief/default"]))
    }

    @Test func aServerRunsTheSameStepsAsAnSSHHost() {
        let plan = ChiefMovePlan(to: "ssh:brain-box", kind: .server(destination: "brain-box"), sourceHome: "/Users/me/.cmux/chief/dev", targetHome: "~/.cmux/chief/default", tokenFile: nil)
        #expect(plan.dryRun == ["chief", "move", "--to", "ssh:brain-box", "--dry-run", "--chief-home", "/Users/me/.cmux/chief/dev"])
        #expect(plan.move == ["chief", "move", "--to", "ssh:brain-box", "--chief-home", "/Users/me/.cmux/chief/dev"])
        #expect(plan.reach == .remote(["ssh", "-o", "BatchMode=yes", "brain-box", "optchat-chief", "move", "reach", "--home", "~/.cmux/chief/default"]))
    }

    @Test func aLocalHomeReachesThroughTheCLI() {
        let plan = ChiefMovePlan(to: "local:/h/new", kind: .local(home: "/h/new"), sourceHome: "/Users/me/.cmux/chief/dev", targetHome: "~/.cmux/chief/default", tokenFile: nil)
        #expect(plan.reach == .cli(["chief", "move", "reach", "--chief-home", "/h/new"]))
    }

    @Test func aCloudMovePassesTheTokenFileAndNeverTheToken() {
        let plan = ChiefMovePlan(to: "cloud:staging", kind: .cloud(staging: true), sourceHome: "/Users/me/.cmux/chief/dev", targetHome: "~/.cmux/chief/default", tokenFile: "/tmp/x/token")
        #expect(plan.dryRun == ["chief", "move", "--to", "cloud:staging", "--dry-run", "--chief-home", "/Users/me/.cmux/chief/dev",
                                "--session-token-file", "/tmp/x/token"])
        #expect(plan.move == ["chief", "move", "--to", "cloud:staging", "--chief-home", "/Users/me/.cmux/chief/dev",
                              "--session-token-file", "/tmp/x/token"])
        #expect(plan.reach == ChiefMovePlan.Reach.none, "a cloud Chief has no home to probe")
    }

    /// The move acts on the home the app shows (a tagged build's own home), never on whatever home
    /// the CLI would pick by itself (the person's real Chief).
    @Test func everyStepNamesTheAppsChiefHome() {
        let plan = ChiefMovePlan(to: "cloud", kind: .cloud(staging: false), sourceHome: "/h/tagged", targetHome: "~/x", tokenFile: nil)
        for step in [plan.dryRun, plan.move] {
            #expect(step.firstIndex(of: "--chief-home").map { step[$0 + 1] } == "/h/tagged")
        }
    }

    /// Roll Back runs `cmux chief move rollback` on the same home; out of the cloud it needs the
    /// session (the hosted brain is turned off), through the same 0600 file.
    @Test func rollbackRunsOnTheAppsHome() {
        #expect(ChiefMovePlan.rollback(sourceHome: "/h/tagged", tokenFile: nil) == ["chief", "move", "rollback", "--chief-home", "/h/tagged"])
        #expect(ChiefMovePlan.rollback(sourceHome: "/h/tagged", tokenFile: "/tmp/t/token")
            == ["chief", "move", "rollback", "--chief-home", "/h/tagged", "--session-token-file", "/tmp/t/token"])
    }
}

/// An SSH target's Chief home is the moving home's path under the user's home folder, as `~/…`.
struct ChiefMoveTargetHomeTests {
    @Test func theHomeUnderTheUsersFolderBecomesATildePath() {
        #expect(ChiefMovePlan.targetHome(home: "/Users/me/.cmux/chief/default", userHome: "/Users/me") == "~/.cmux/chief/default")
        #expect(ChiefMovePlan.targetHome(home: "/Users/me/.cmux/chief/default", userHome: "/Users/me/") == "~/.cmux/chief/default")
    }

    @Test func aHomeOutsideTheUsersFolderKeepsItsPath() {
        #expect(ChiefMovePlan.targetHome(home: "/opt/chief", userHome: "/Users/me") == "/opt/chief")
    }
}
