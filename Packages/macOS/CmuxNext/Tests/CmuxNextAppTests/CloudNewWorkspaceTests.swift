import CmuxNextActions
import CmuxNextCloud
import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextApp

/// The Cloud toggle (#26062): a person's New Workspace with `cloud.newWorkspacesInCloud` on goes to a
/// new Cloud machine of its own, starting in the person's folder (its git working copy, copied
/// there) or in the machine's empty folder. Read from the same cmux.json the app reads, against a
/// real folder on disk and a stand-in for `cmux link sync push`; no VM.
@MainActor @Suite(.serialized)
struct CloudNewWorkspaceTests {
    static func settings(inCloud: Bool?, folder: String? = nil) -> CmuxNextSettings.JSONValue {
        var cloud: [String: CmuxNextSettings.JSONValue] = [:]
        if let inCloud { cloud["newWorkspacesInCloud"] = .bool(inCloud) }
        if let folder { cloud["newWorkspaceFolder"] = .string(folder) }
        return .object(["cloud": .object(cloud)])
    }

    /// A git working copy with a nested folder, as a project on this Mac.
    static func project() throws -> (root: String, nested: String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-new-ws-\(UUID().uuidString)/app").path
        try FileManager.default.createDirectory(atPath: root + "/.git", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/src/ui", withIntermediateDirectories: true)
        return (root, root + "/src/ui")
    }

    @Test func offByDefaultKeepsNewWorkspacesOnThisMac() throws {
        let (_, nested) = try Self.project()
        let person = ActionInvocation(origin: .user)
        #expect(CloudNewWorkspace.plan(person, cwd: nested, settings: .object([:])) == nil)
        #expect(CloudNewWorkspace.plan(person, cwd: nested, settings: Self.settings(inCloud: false)) == nil)
        #expect(CloudNewWorkspace.plan(person, cwd: nested, settings: nil) == nil, "no settings loaded yet: local")
    }

    @Test func onSendsAPersonsNewWorkspaceToANewMachineWithItsWorkingCopy() throws {
        let (root, nested) = try Self.project()
        let plan = try #require(CloudNewWorkspace.plan(ActionInvocation(origin: .user), cwd: nested, settings: Self.settings(inCloud: true)))
        #expect(plan.folder?.root == root, "the whole working copy is copied, not only the nested folder")
        #expect(plan.folder?.subpath == "src/ui", "the workspace opens where the person was")
        #expect(plan.workspaceName == "app")
    }

    @Test func emptyFolderStartsWithNothingCopied() throws {
        let (_, nested) = try Self.project()
        let plan = try #require(CloudNewWorkspace.plan(ActionInvocation(origin: .user), cwd: nested, settings: Self.settings(inCloud: true, folder: "empty")))
        #expect(plan.folder == nil)
        #expect(plan.workspaceName == nil)
    }

    @Test func aHomeFolderOrNoFolderStartsEmptyInsteadOfCopyingIt() throws {
        let on = Self.settings(inCloud: true)
        let home = try #require(CloudNewWorkspace.plan(ActionInvocation(origin: .user), cwd: NSHomeDirectory(), settings: on))
        #expect(home.folder == nil, "a home folder is never copied to a machine")
        let none = try #require(CloudNewWorkspace.plan(ActionInvocation(origin: .user), cwd: nil, settings: on))
        #expect(none.folder == nil)
    }

    @Test func scriptsAndANamedMachineAreNotRerouted() throws {
        let (_, nested) = try Self.project()
        let on = Self.settings(inCloud: true)
        #expect(CloudNewWorkspace.plan(ActionInvocation(origin: .cli), cwd: nested, settings: on) == nil, "`cmux workspace new` stays where it was asked")
        var named = ActionInvocation(origin: .user)
        named.arguments["machine"] = .string("machine:vm-1")
        #expect(CloudNewWorkspace.plan(named, cwd: nested, settings: on) == nil)
    }

    /// A person's run that carries a command keeps it on this Mac; an app that can't copy a folder
    /// (no bundled CLI, or the app server link) starts the machine empty instead of failing after it exists.
    @Test func aCommandStaysLocalAndAnAppThatCannotCopyStartsEmpty() throws {
        let (_, nested) = try Self.project()
        let on = Self.settings(inCloud: true)
        var command = ActionInvocation(origin: .user)
        command.arguments["command"] = .string("make")
        #expect(CloudNewWorkspace.plan(command, cwd: nested, settings: on) == nil)
        let plan = try #require(CloudNewWorkspace.plan(ActionInvocation(origin: .user), cwd: nested, settings: on, canCopy: false))
        #expect(plan.folder == nil)
    }

    /// The copy goes to the image's work user's `~/work`; an older image without that user refuses
    /// it and the copy goes to root's.
    @Test func theFolderIsCopiedUnderTheFirstWorkRootTheMachineAllows() async throws {
        let (root, nested) = try Self.project()
        let folder = try #require(CloudMoveFolder(chat: nested))
        var pushes: [String] = []
        let remote = try await CloudNewWorkspace.sync(folder, socket: "/tmp/vm.sock", machine: "vm", workRoots: ["/home/cmux/work", "/root/work"]) { socket, local, remote in
            #expect(socket == "/tmp/vm.sock")
            #expect(local == root)
            pushes.append(remote)
            return remote.hasPrefix("/home/") ? CloudMoveCLI.Answer(ok: false, errorCode: "fs.permission_denied") : CloudMoveCLI.Answer(ok: true)
        }
        #expect(pushes == [folder.remote(under: "/home/cmux/work").folder, folder.remote(under: "/root/work").folder])
        #expect(remote.chat == folder.remote(under: "/root/work").folder + "/src/ui")
    }

    @Test func aFailedCopySaysWhyAndOpensNothing() async throws {
        let (_, nested) = try Self.project()
        let folder = try #require(CloudMoveFolder(chat: nested))
        await #expect(throws: ActionFailure.self) {
            _ = try await CloudNewWorkspace.sync(folder, socket: "s", machine: "vm", workRoots: ["/home/cmux/work", "/root/work"]) { _, _, _ in
                CloudMoveCLI.Answer(ok: false, errorCode: "io", error: "disk full")
            }
        }
    }
}
