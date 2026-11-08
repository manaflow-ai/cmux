import CmuxNextActions
import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextCloud
import CmuxNextCloudUI
import Foundation
import Testing

/// `cmux cloud start-session --from-folder PATH` (`cmux cloud start-chat --from-folder`): a folder on this Mac is
/// copied to the machine as the composer's Cloud start copies one, refused as that start refuses one, and the
/// same start again on the same machine is the same copy.
@MainActor @Suite
struct CloudStartSessionFolderTests {
    static let home = "/Users/me"

    /// The person's own run in this app (``ActionInvocation/isPersonsOwnRun``), the only one that copies.
    static func request(_ arguments: [String: ActionValue]) throws -> CloudStartSession.Request {
        try CloudStartSession.request(CloudStartSessionTests.invocation(target: "vm-a", arguments.merging(["agent": .string("claude")]) { $1 }, origin: .user))
    }

    static func fromFolder(_ folder: String, cwd: String? = nil) throws -> String? {
        try CloudStartSession.fromFolder(CloudStartSessionTests.invocation(["fromFolder": .string(folder)], origin: .user), cwd: cwd, home: home)
    }

    /// Every way a run reaches start-session: each origin, from the control socket or in this app, naming an agent
    /// session, a terminal (`caller.terminal_id`) or neither.
    static func runs(_ arguments: [String: ActionValue], target: String? = nil) -> [ActionInvocation] {
        let callers: [(socket: Bool, agent: String?, terminal: String?)] = [(false, nil, nil), (true, nil, nil), (true, nil, "term_1"), (false, nil, "term_1"), (true, "chat-1", nil)]
        return ActionOrigin.allCases.flatMap { origin in
            callers.map { caller in
                var invocation = CloudStartSessionTests.invocation(target: target, arguments, origin: origin, agent: caller.agent)
                invocation.viaControlSocket = caller.socket
                invocation.callerTerminal = caller.terminal
                return invocation
            }
        }
    }

    static func label(_ invocation: ActionInvocation) -> Comment {
        "\(invocation.origin) socket=\(invocation.viaControlSocket) agent=\(invocation.callerAgentSession ?? "-") terminal=\(invocation.callerTerminal ?? "-")"
    }

    /// A Mac folder goes to the machine for every run that may write a file there (`cloudFileWrite`, which takes every
    /// origin, as `cloudExec` runs any command): refusing one of those runs a copy would guard nothing. This Mac's
    /// CLI, a socket caller saying `cli` (with or without its terminal), a script and an agent all copy.
    @Test func everyRunThatMayWriteToTheMachineCopiesAFolder() throws {
        for invocation in Self.runs(["fromFolder": .string("/Users/me/code/app")]) {
            #expect(try CloudStartSession.fromFolder(invocation, cwd: nil, home: Self.home) == "/Users/me/code/app", Self.label(invocation))
        }
        // Without a folder nothing is copied.
        #expect(try CloudStartSession.fromFolder(CloudStartSessionTests.invocation([:], origin: .mcp), cwd: nil, home: Self.home) == nil)
    }

    /// fromFolder's origin policy is cloudFileWrite's, so the two cannot drift: cloudFileWrite answers every run as it
    /// answers the person's own run, and fromFolder copies for exactly the runs cloudFileWrite answers so.
    @Test func theFoldersOriginPolicyIsCloudFileWrites() throws {
        let f = CloudStartSessionTests.fixture()
        let write = try #require(f.services.registry.action(for: "cloudFileWrite")?.invoke, "cloudFileWrite is not bound")
        let file: [String: ActionValue] = ["path": .string("/home/cmux/notes.txt"), "contents": .string("x")]
        func refusal(_ invocation: ActionInvocation) -> String? { f.services.registry.capturingRefusal { write(invocation) } }
        func copies(_ invocation: ActionInvocation) -> Bool {
            var folder = invocation
            folder.arguments = ["fromFolder": .string("/Users/me/code/app")]
            return (try? CloudStartSession.fromFolder(folder, cwd: nil, home: Self.home)) != nil
        }
        let person = CloudStartSessionTests.invocation(target: f.session.machineID, file, origin: .user)
        let writesForPerson = refusal(person) == nil
        #expect(copies(person))
        for invocation in Self.runs(file, target: f.session.machineID) {
            let writesAsForPerson = (refusal(invocation) == nil) == writesForPerson
            #expect(writesAsForPerson, "cloudFileWrite: \(Self.label(invocation))")
            #expect(copies(invocation) == writesAsForPerson, "fromFolder: \(Self.label(invocation))")
        }
    }

    /// The copy goes only to a machine whose link said this account owns it, whoever asks: an owned one takes it, a
    /// machine with no owner answer (a teammate's, or not linked yet) takes none.
    @Test func aCLIRunCopiesToAnOwnedMachineAndNotToAnotherOne() async throws {
        let services = MachineIconTests.services()
        let owned = CloudTestLink.session(id: "vm-owned", name: "mine", owns: true, mainWork: services.mainWork)
        let other = CloudTestLink.session(id: "vm-other", name: "teammate-box", owns: false, mainWork: services.mainWork)
        for session in [owned, other] { _ = try await #require(session.appLink).connect(origin: .script) }
        for invocation in Self.runs(["fromFolder": .string("/Users/me/code/app")]) where [.cli, .script].contains(invocation.origin) {
            #expect(try CloudStartSession.fromFolder(invocation, cwd: nil, home: Self.home) == "/Users/me/code/app", Self.label(invocation))
        }
        try await CloudStartSession.requireOwned(owned)
        await #expect(throws: ActionFailure(message: CloudStartSessionStrings.fromFolderNotOwned("teammate-box"))) {
            try await CloudStartSession.requireOwned(other)
        }
    }

    /// The copy waits on the machine's owner answer: a machine whose link has not said this account owns it (a
    /// teammate's, or no link yet) is not one a Mac folder goes to, so it would keep no copy after refusing the chat.
    @Test func aMachineNotSaidToBeTheAccountsOwnGetsNoCopy() async {
        let f = CloudStartSessionTests.fixture()
        #expect(await CloudMove.ownerAnswer(f.session).vmKind != "owner")
        #expect(CloudStartSessionStrings.fromFolderNotOwned("teammate-box").contains("teammate-box"))
    }

    @Test func theFolderIsAnAbsolutePathOfThisMacWrittenPlain() throws {
        #expect(try Self.fromFolder("/Users/me/code/app/") == "/Users/me/code/app")
        #expect(try Self.fromFolder("/Users/me/code/./app/../web") == "/Users/me/code/web")
        let request = try Self.request(["fromFolder": .string("/tmp/probe small")])
        #expect(request.fromFolder == "/tmp/probe small" && request.cwd == nil)
        #expect(request.command == "cmux cloud start-session --target machine:vm-a --agent claude --from-folder '/tmp/probe small'")
        #expect(try Self.request(["fromFolder": .string(" ")]).fromFolder == nil)
    }

    @Test(arguments: ["code/app", "~/code/app", "/a\u{7}b", "/.."])
    func aFolderThatIsNoAbsolutePathIsRefused(folder: String) {
        #expect(throws: ActionFailure(message: CloudStartSessionStrings.fromFolderInvalid)) { try Self.fromFolder(folder) }
    }

    @Test func itNeverGoesWithCwd() {
        #expect(throws: ActionFailure(message: CloudStartSessionStrings.fromFolderWithCwd)) {
            try Self.request(["fromFolder": .string("/tmp/app"), "cwd": .string("/home/cmux/work")])
        }
    }

    @Test(arguments: ["/", "/Users", "/Users/me", "/Users/me/"])
    func homeAboveItAndTheDisksRootAreRefused(folder: String) {
        let written = CloudMoveFolder.normalized(folder) ?? folder
        #expect(throws: ActionFailure(message: CloudStartSessionStrings.fromFolderTooBroad(written))) { try Self.fromFolder(folder) }
    }

    /// The credential folders the composer's start never copies (#35019), a folder under one, and a folder holding one:
    /// gh's OAuth tokens (`~/.config/gh/hosts.yml`) and Cargo's registry token (`~/.cargo/credentials.toml`) too.
    @Test(arguments: [("/Users/me/.ssh", "~/.ssh"), ("/Users/me/.SSH/keys", "~/.ssh"), ("/Users/me/.config", "~/.config/gcloud"),
                      ("/Users/me/Library/Keychains", "~/Library/Keychains"), ("/Users/me/.config/gh", "~/.config/gh"),
                      ("/Users/me/.config/gh/extensions", "~/.config/gh"), ("/Users/me/.cargo", "~/.cargo"),
                      ("/Users/me/.cargo/registry/src", "~/.cargo"), ("/Users/me/.kube", "~/.kube"), ("/Users/me/.gem", "~/.gem"),
                      ("/Users/me/.terraform.d", "~/.terraform.d"), ("/Users/me/.password-store", "~/.password-store")])
    func aCredentialFolderIsRefused(folder: String, secret: String) {
        for invocation in Self.runs(["fromFolder": .string(folder)]) {
            #expect(throws: ActionFailure(message: CloudStartSessionStrings.fromFolderSecret(folder, secret: secret)), Self.label(invocation)) {
                try CloudStartSession.fromFolder(invocation, cwd: nil, home: Self.home)
            }
        }
    }

    @Test func aRefusalOnDiskSaysWhichOne() {
        #expect(CloudStartSession.message(.missing, folder: "/x") == CloudStartSessionStrings.fromFolderMissing("/x"))
        #expect(CloudStartSession.message(.homeOrAbove, folder: "/x") == CloudStartSessionStrings.fromFolderTooBroad("/x"))
        #expect(CloudStartSession.message(.secret("~/.aws"), folder: "/x") == CloudStartSessionStrings.fromFolderSecret("/x", secret: "~/.aws"))
    }

    /// The copy's key is the ledger's: the same machine and folder are the same copy, which a retry reuses.
    @Test func theCopyKeyIsAStableUUIDOfTheMachineAndTheFolder() {
        let key = CloudMoveFolder.copyKey(machine: "vm-a", folder: "/Users/me/code/app")
        #expect(UUID(uuidString: key) != nil && key.count == 36 && key == key.lowercased())
        #expect(key == CloudMoveFolder.copyKey(machine: "vm-a", folder: "/Users/me/code/app"))
        #expect(key != CloudMoveFolder.copyKey(machine: "vm-b", folder: "/Users/me/code/app"))
        #expect(key != CloudMoveFolder.copyKey(machine: "vm-a", folder: "/Users/me/code/web"))
    }

    @Test func runsOfAnotherFolderAreOtherRuns() {
        let plain = CloudStartSession.Request(machineID: "vm-a", name: nil, agent: "claude", cwd: nil)
        var copied = plain
        copied.fromFolder = "/Users/me/code/app"
        #expect(CloudStartRunKey(plain, caller: nil, account: ["u", "t"]) != CloudStartRunKey(copied, caller: nil, account: ["u", "t"]))
    }

    @Test func theVerbOffersTheArgument() throws {
        let descriptor = try #require(CloudStartSessionTests.fixture().services.registry.descriptor(for: CloudStartSession.action))
        #expect(descriptor.arguments.contains { $0.name == "fromFolder" && !$0.isRequired })
        #expect(descriptor.description?.contains("--from-folder") == true)
    }

    /// The composer's check, shared: a folder on disk answers its canonical path and the Git working copy it copies;
    /// home is refused.
    @Test func theSharedCheckAnswersTheFolderAndItsWorkingCopy() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("from-folder-\(UUID().uuidString)")
        let sub = base.appendingPathComponent("app/src")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: base.appendingPathComponent("app/.git"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let checked = try await AgentPaneCloudStart.checkedFolder(sub.path, home: NSHomeDirectory()).get()
        #expect(checked.folder.hasSuffix("/app/src") && checked.root.hasSuffix("/app") && checked.folder.hasPrefix(checked.root + "/"))
        let home = await AgentPaneCloudStart.checkedFolder(NSHomeDirectory(), home: NSHomeDirectory())
        #expect(throws: AgentPaneCloudFolderRefusal.homeOrAbove) { try home.get() }
        let gone = await AgentPaneCloudStart.checkedFolder(base.appendingPathComponent("gone").path, home: NSHomeDirectory())
        #expect(throws: AgentPaneCloudFolderRefusal.missing) { try gone.get() }
    }
}
