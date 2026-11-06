import CmuxNextCloud
import CmuxNextSettings
import Foundation
import Testing

/// The Cloud toggle (#26062): a person's New Workspace with `cloud.newWorkspacesInCloud` on goes to a
/// new Cloud machine of its own, starting in the person's folder (its git working copy, copied
/// there) or in the machine's empty folder. Read from the same cmux.json values the app reads,
/// against a real folder on disk and a stand-in for `cmux link sync push`; no VM.
@Suite(.serialized)
struct CloudNewWorkspaceTests {
    static func settings(inCloud: Bool?, folder: String? = nil) -> JSONValue {
        var cloud: [String: JSONValue] = [:]
        if let inCloud { cloud["newWorkspacesInCloud"] = .bool(inCloud) }
        if let folder { cloud["newWorkspaceFolder"] = .string(folder) }
        return .object(["cloud": .object(cloud)])
    }

    /// The plan the app makes from cmux.json `root` for a person's Cmd-N in `cwd` (CloudHandlers.startNewWorkspaceInCloud).
    static func plan(_ root: JSONValue, cwd: String?, byPerson: Bool = true, namesMachineOrCommand: Bool = false,
                     canCopy: Bool = true) -> CloudNewWorkspacePlan? {
        let setting = CloudNewWorkspaceSetting()
        return CloudNewWorkspacePlan(inCloud: setting.inCloud(in: root), inheritsFolder: canCopy && setting.folder(in: root) == .inherit, cwd: cwd,
                                     byPerson: byPerson, namesMachineOrCommand: namesMachineOrCommand)
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
        #expect(Self.plan(.object([:]), cwd: nested) == nil)
        #expect(Self.plan(Self.settings(inCloud: false), cwd: nested) == nil)
    }

    @Test func onSendsAPersonsNewWorkspaceToANewMachineWithItsWorkingCopy() throws {
        let (root, nested) = try Self.project()
        let plan = try #require(Self.plan(Self.settings(inCloud: true), cwd: nested))
        let folder = try #require(plan.resolvedFolder())
        #expect(folder.root == root, "the whole working copy is copied, not only the nested folder")
        #expect(folder.subpath == "src/ui", "the workspace opens where the person was")
    }

    /// A folder outside any git working copy (`/Users`, `~/Downloads`, a disk) is never copied:
    /// it could hold anything. The workspace starts in the machine's empty folder.
    @Test func aPlainFolderOutsideGitIsNotCopied() throws {
        let plain = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-new-ws-\(UUID().uuidString)/Downloads").path
        try FileManager.default.createDirectory(atPath: plain + "/big", withIntermediateDirectories: true)
        #expect(try #require(Self.plan(Self.settings(inCloud: true), cwd: plain + "/big")).resolvedFolder() == nil)
    }

    @Test func emptyFolderStartsWithNothingCopied() throws {
        let (_, nested) = try Self.project()
        let plan = try #require(Self.plan(Self.settings(inCloud: true, folder: "empty"), cwd: nested))
        #expect(plan.source == nil)
        #expect(plan.resolvedFolder() == nil)
    }

    @Test func aHomeFolderOrNoFolderStartsEmptyInsteadOfCopyingIt() throws {
        let on = Self.settings(inCloud: true)
        #expect(try #require(Self.plan(on, cwd: NSHomeDirectory())).resolvedFolder() == nil, "a home folder is never copied to a machine")
        #expect(try #require(Self.plan(on, cwd: nil)).resolvedFolder() == nil)
    }

    @Test func scriptsANamedMachineAndACommandAreNotRerouted() throws {
        let (_, nested) = try Self.project()
        let on = Self.settings(inCloud: true)
        #expect(Self.plan(on, cwd: nested, byPerson: false) == nil, "`cmux workspace new` stays where it was asked")
        #expect(Self.plan(on, cwd: nested, namesMachineOrCommand: true) == nil)
    }

    /// No bundled CLI, or the app server link: the machine starts empty rather than fail after it exists.
    @Test func anAppThatCannotCopyStartsTheMachineEmpty() throws {
        let (_, nested) = try Self.project()
        #expect(try #require(Self.plan(Self.settings(inCloud: true), cwd: nested, canCopy: false)).source == nil)
    }

    /// The copy goes to the image's work user's `~/work`; an older image without that user refuses
    /// it and the copy goes to root's.
    @Test func theFolderIsCopiedUnderTheFirstWorkRootTheMachineAllows() async throws {
        let (_, nested) = try Self.project()
        let folder = try #require(CloudMoveFolder(chat: nested))
        var pushes: [String] = []
        let remote = try await CloudNewWorkspacePlan.copy(folder, workRoots: ["/home/cmux/work", "/root/work"]) { remote in
            pushes.append(remote)
            return remote.hasPrefix("/home/") ? .init(ok: false, errorCode: "fs.permission_denied") : .init(ok: true)
        }
        #expect(pushes == [folder.remote(under: "/home/cmux/work").folder, folder.remote(under: "/root/work").folder])
        #expect(remote.chat == folder.remote(under: "/root/work").folder + "/src/ui")
    }

    @Test func aFailedCopySaysWhyAndStopsAtTheFirstRealRefusal() async throws {
        let (_, nested) = try Self.project()
        let folder = try #require(CloudMoveFolder(chat: nested))
        var pushes = 0, failure: CloudNewWorkspacePlan.CopyFailure?
        do {
            _ = try await CloudNewWorkspacePlan.copy(folder, workRoots: ["/home/cmux/work", "/root/work"]) { _ in
                pushes += 1
                return .init(ok: false, errorCode: "io", error: "disk full")
            }
        } catch let error as CloudNewWorkspacePlan.CopyFailure {
            failure = error
        }
        #expect(failure == .failed("disk full"))
        #expect(pushes == 1, "a refusal other than permission is not tried under the next root")
        await #expect(throws: CloudNewWorkspacePlan.CopyFailure.outdated) {
            _ = try await CloudNewWorkspacePlan.copy(folder, workRoots: ["/home/cmux/work"]) { _ in .init(ok: false, errorCode: "machine_outdated") }
        }
    }

    /// A machine is asked for only where Cloud can make it and a window shows its progress; every
    /// other case opens here with its reason (#26078 review).
    @Test func theRouteNeedsCloudASignInAndAWindow() {
        #expect(CloudNewWorkspacePlan.route(unavailableReason: nil, signedIn: true, hasWindow: true) == .cloud)
        #expect(CloudNewWorkspacePlan.route(unavailableReason: nil, signedIn: true, hasWindow: false) == .thisMac(.noWindow))
        #expect(CloudNewWorkspacePlan.route(unavailableReason: nil, signedIn: false, hasWindow: true) == .thisMac(.signedOut))
        #expect(CloudNewWorkspacePlan.route(unavailableReason: "off", signedIn: true, hasWindow: true) == .thisMac(.unavailable("off")))
    }
}
