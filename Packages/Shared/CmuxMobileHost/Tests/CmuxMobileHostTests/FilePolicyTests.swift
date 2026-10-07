import CmuxMobileHost
import Foundation
import Testing

@Suite("Files path policy")
struct FilePolicyTests {
    @Test func rootsMustBeStrictlyInsideHomeAndUnprotected() throws {
        let f = try FilesFixture()
        defer { f.remove() }
        let candidates = [
            MobileFileRoot(id: "home", name: "home", url: f.home, writable: true),
            MobileFileRoot(id: "slash", name: "/", url: URL(fileURLWithPath: "/"), writable: true),
            MobileFileRoot(id: "outside", name: "tmp", url: f.home.deletingLastPathComponent(), writable: true),
            MobileFileRoot(id: "lib", name: "lib", url: f.home.appendingPathComponent("Library/Foo"), writable: true),
            MobileFileRoot(id: "ssh", name: "ssh", url: f.home.appendingPathComponent(".ssh"), writable: true),
            MobileFileRoot(id: "ws_a1", name: "proj", url: f.workspace, writable: true),
        ]
        let policy = MobileFilePolicy(configuration: f.configuration, roots: candidates)
        #expect(policy.roots.map(\.root.id) == ["inbox", "ws_a1"])
    }

    @Test func pathsInsideARootResolve() throws {
        let f = try FilesFixture()
        defer { f.remove() }
        try Data("x".utf8).write(to: f.workspace.appendingPathComponent("a.txt"))
        let resolved = try f.policy.resolveExisting("~/src/proj/a.txt")
        #expect(resolved.root.root.id == "ws_a1")
        #expect(resolved.path.hasSuffix("/src/proj/a.txt"))
        #expect(throws: MobileDaemonError.self) { try f.policy.resolveExisting("~/src/proj/missing.txt") }
        do {
            _ = try f.policy.resolveExisting("~/src/proj/missing.txt")
        } catch {
            #expect(error.code == "files.not_found")
        }
    }

    @Test func escapesAreForbidden() throws {
        let f = try FilesFixture()
        defer { f.remove() }
        let escapes = ["~/src/proj/../../secret.txt", "/etc/passwd", f.secret.path, "~", "~/src/proj/../proj/../../secret.txt",
                       "~/src/proj/new/../../../secret.txt"]
        for path in escapes {
            #expect(code { try f.policy.resolve(path) } == "files.forbidden", "\(path)")
        }
        #expect(code { try f.policy.resolve("a.txt") } == "validation.invalid")
        #expect(code { try f.policy.resolve("~/src/proj/a\0b") } == "validation.invalid")
    }

    @Test func symlinksLeavingEveryRootAreForbidden() throws {
        let f = try FilesFixture()
        defer { f.remove() }
        let fm = FileManager.default
        try fm.createSymbolicLink(at: f.workspace.appendingPathComponent("out.txt"), withDestinationURL: f.secret)
        try fm.createSymbolicLink(at: f.workspace.appendingPathComponent("up"), withDestinationURL: f.home)
        try Data("in".utf8).write(to: f.workspace.appendingPathComponent("real.txt"))
        try fm.createSymbolicLink(at: f.workspace.appendingPathComponent("alias.txt"),
                                  withDestinationURL: f.workspace.appendingPathComponent("real.txt"))
        #expect(code { try f.policy.resolveExisting("~/src/proj/out.txt") } == "files.forbidden")
        #expect(code { try f.policy.resolveExisting("~/src/proj/up/secret.txt") } == "files.forbidden")
        #expect(code { try f.policy.resolve("~/src/proj/up/new.txt") } == "files.forbidden")
        #expect(try f.policy.resolveExisting("~/src/proj/alias.txt").path.hasSuffix("/proj/real.txt"))
        // A root that is itself a symlink to home is refused after canonicalization.
        try fm.createSymbolicLink(at: f.home.appendingPathComponent("src/homelink"), withDestinationURL: f.home)
        let sneaky = MobileFilePolicy(configuration: f.configuration, roots: [
            MobileFileRoot(id: "x", name: "x", url: f.home.appendingPathComponent("src/homelink"), writable: true),
        ])
        #expect(sneaky.roots.map(\.root.id) == ["inbox"])
    }

    @Test func deniedNamesAreNeverServed() throws {
        let f = try FilesFixture()
        defer { f.remove() }
        try FileManager.default.createDirectory(at: f.workspace.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
        try Data("k".utf8).write(to: f.workspace.appendingPathComponent(".ssh/id_ed25519"))
        #expect(code { try f.policy.resolveExisting("~/src/proj/.ssh/id_ed25519") } == "files.forbidden")
        #expect(code { try f.policy.resolve("~/src/proj/.netrc") } == "files.forbidden")
        #expect(code { try f.policy.resolve("~/src/proj/.SSH/id_ed25519") } == "files.forbidden")
        #expect(MobileFilePolicy.sanitizedName("ID_RSA") == "_ID_RSA")
    }

    @Test func uploadNamesAreSanitizedAndNeverOverwrite() throws {
        #expect(MobileFilePolicy.sanitizedName("../../x") == "x")
        #expect(MobileFilePolicy.sanitizedName(".ssh") == "ssh")
        #expect(MobileFilePolicy.sanitizedName("id_rsa") == "_id_rsa")
        #expect(MobileFilePolicy.sanitizedName("  ") == "file")
        #expect(MobileFilePolicy.sanitizedName("a\u{1}b:c.png") == "abc.png")
        #expect(MobileFilePolicy.sanitizedName(String(repeating: "n", count: 300) + ".jpeg").utf8.count == 255)
        let f = try FilesFixture()
        defer { f.remove() }
        let first = try MobileFilePolicy.createUniqueFile(in: f.workspace.path, name: "a.txt")
        let second = try MobileFilePolicy.createUniqueFile(in: f.workspace.path, name: "a.txt")
        #expect(first.hasSuffix("/a.txt"))
        #expect(second.hasSuffix("/a (2).txt"))
    }

    private func code(_ body: () throws -> some Any) -> String? {
        do {
            _ = try body()
            return nil
        } catch let error as MobileDaemonError {
            return error.code
        } catch {
            return "\(error)"
        }
    }
}
