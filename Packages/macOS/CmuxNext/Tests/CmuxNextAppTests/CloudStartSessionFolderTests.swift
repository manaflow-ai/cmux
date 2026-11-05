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

    static func request(_ arguments: [String: ActionValue]) throws -> CloudStartSession.Request {
        try CloudStartSession.request(CloudStartSessionTests.invocation(target: "vm-a", arguments.merging(["agent": .string("claude")]) { $1 }))
    }

    static func fromFolder(_ folder: String, cwd: String? = nil) throws -> String? {
        try CloudStartSession.fromFolder(CloudStartSessionTests.invocation(["fromFolder": .string(folder)]), cwd: cwd, home: home)
    }

    @Test func anAgentsRunNeverCopiesAFolderFromThisMac() throws {
        let request = try Self.request(["fromFolder": .string("/Users/me/code/app")])
        let mcp = CloudStartSessionTests.invocation(["fromFolder": .string("/Users/me/code/app")], origin: .mcp)
        let chat = CloudStartSessionTests.invocation(["fromFolder": .string("/Users/me/code/app")], agent: "chat-1")
        #expect(CloudStartSession.isAgent(mcp) && CloudStartSession.isAgent(chat))
        #expect(throws: ActionFailure(message: CloudStartSessionStrings.fromFolderAgent)) { try CloudStartSession.refuseAgentFolder(request) }
        // Without a folder an agent's start is asked as before.
        try CloudStartSession.refuseAgentFolder(try Self.request([:]))
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

    /// The credential folders the composer's start never copies (#35019), and a folder holding one.
    @Test(arguments: [("/Users/me/.ssh", "~/.ssh"), ("/Users/me/.SSH/keys", "~/.ssh"), ("/Users/me/.config", "~/.config/gcloud"),
                      ("/Users/me/Library/Keychains", "~/Library/Keychains")])
    func aCredentialFolderIsRefused(folder: String, secret: String) {
        #expect(throws: ActionFailure(message: CloudStartSessionStrings.fromFolderSecret(folder, secret: secret))) { try Self.fromFolder(folder) }
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
