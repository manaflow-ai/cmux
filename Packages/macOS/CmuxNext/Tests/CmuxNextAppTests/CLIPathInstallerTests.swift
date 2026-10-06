import CmuxNextActions
@testable import CmuxNextApp
import Foundation
import Testing

/// Install cmux CLI in PATH: a symlink to the bundled CLI, replaced when it
/// exists, and an administrator retry when the folder is not writable. The
/// retry runs through a stand-in that executes the command with /bin/sh, so
/// the quoting is exercised on paths with spaces and quotes.
struct CLIPathInstallerTests {
    private struct Sandbox {
        let root: URL
        let source: URL
        let destination: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("cli it's \(UUID().uuidString)")
            source = root.appendingPathComponent("cmux DEV.app/Contents/Resources/bin/cmux")
            destination = root.appendingPathComponent("usr local/bin/cmux")
            try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\n".utf8).write(to: source)
        }

        func installer(privileged: @escaping CLIPathInstaller.Privileged = { _ in Issue.record("unexpected administrator prompt") })
            -> CLIPathInstaller {
            CLIPathInstaller(destination: destination, source: source, privileged: privileged)
        }

        func readOnlyParent() throws {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: destination.deletingLastPathComponent().path)
        }

        func cleanUp() {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.deletingLastPathComponent().path)
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// Runs the administrator command as this user after making the folder
    /// writable, as the prompt would with root.
    private static func shell(unlocking folder: URL, ran: Ran) -> CLIPathInstaller.Privileged {
        { command in
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            let exited = AsyncStream.makeStream(of: Int32.self, bufferingPolicy: .bufferingNewest(1))
            process.terminationHandler = { exited.continuation.yield($0.terminationStatus); exited.continuation.finish() }
            try process.run()
            for await status in exited.stream where status != 0 {
                throw CLIPathInstaller.Failure.privilegedCommandFailed(message: "sh \(status)")
            }
            ran.mark()
        }
    }

    private nonisolated final class Ran: @unchecked Sendable {
        private(set) var count = 0
        func mark() { count += 1 }
    }

    /// A file that is not this app's link is refused unless the caller
    /// chose to replace it, and the outcome then names what it replaced.
    @Test func refusesAFileUnlessReplacing() async throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        try FileManager.default.createDirectory(at: box.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("old".utf8).write(to: box.destination)
        await #expect(throws: CLIPathInstaller.Failure.occupied(path: box.destination.path, existing: .file)) {
            try await box.installer().install()
        }
        #expect(try String(contentsOf: box.destination, encoding: .utf8) == "old", "a refusal leaves the file alone")
        let outcome = try await box.installer().install(replacing: true)
        #expect(outcome == .init(usedAdministratorPrivileges: false, destination: box.destination, source: box.source.standardizedFileURL,
                                 replaced: .file))
        #expect(box.installer().isInstalled())
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: box.destination.path) == box.source.path)
    }

    /// Install never shadows another app's `cmux` silently: a link to
    /// another bundle's CLI is refused; reinstalling over this app's own
    /// link stays silent.
    @Test func refusesAnotherAppsLinkUnlessReplacing() async throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        try FileManager.default.createDirectory(at: box.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let other = "/Applications/cmux.app/Contents/Resources/bin/cmux"
        try FileManager.default.createSymbolicLink(atPath: box.destination.path, withDestinationPath: other)
        await #expect(throws: CLIPathInstaller.Failure.occupied(path: box.destination.path, existing: .link(target: other))) {
            try await box.installer().install()
        }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: box.destination.path) == other)
        let replaced = try await box.installer().install(replacing: true)
        #expect(replaced.replaced == .link(target: other))
        let again = try await box.installer().install()
        #expect(again.replaced == nil, "reinstalling over this app's own link replaces nothing")
    }

    /// `cmux-next` is the name that never shadows another app's `cmux`.
    @Test func theCmuxNextNameSitsBesideTheOtherCLI() async throws {
        #expect(CLIPathInstaller.Name.cmuxNext.destination.path == "/usr/local/bin/cmux-next")
        #expect(CLIPathInstaller.Name.cmux.destination.path == "/usr/local/bin/cmux")
        let box = try Sandbox()
        defer { box.cleanUp() }
        try FileManager.default.createDirectory(at: box.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let other = "/Applications/cmux.app/Contents/Resources/bin/cmux"
        try FileManager.default.createSymbolicLink(atPath: box.destination.path, withDestinationPath: other)
        let beside = box.destination.deletingLastPathComponent().appendingPathComponent("cmux-next")
        let outcome = try await CLIPathInstaller(destination: beside, source: box.source, privileged: { _ in }).install()
        #expect(outcome.replaced == nil)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: box.destination.path) == other)
    }

    @Test @MainActor func theRefusalExplainsBothChoices() {
        let text = CLIInstallStrings.message(CLIPathInstaller.Failure.occupied(
            path: "/usr/local/bin/cmux", existing: .link(target: "/Applications/cmux.app/Contents/Resources/bin/cmux")))
        #expect(text.contains("/Applications/cmux.app/Contents/Resources/bin/cmux"), "\(text)")
        #expect(text.contains("--replace"), "\(text)")
        #expect(text.contains("/usr/local/bin/cmux-next"), "\(text)")
    }

    @Test func theCLIActionTakesReplaceAndCmuxNext() throws {
        let action = try #require(ActionCatalog.all.first { $0.id == "palette.installCLI" })
        #expect(action.arguments.map(\.name) == ["replace", "cmux_next"])
        #expect(action.arguments.allSatisfy { $0.kind == .bool && !$0.isRequired })
    }

    @Test @MainActor func theSheetNamesWhatWasReplaced() {
        let outcome = CLIPathInstaller.InstallOutcome(usedAdministratorPrivileges: false, destination: URL(fileURLWithPath: "/usr/local/bin/cmux"),
                                                      source: URL(fileURLWithPath: "/Applications/cmux NEXT.app/Contents/Resources/bin/cmux"),
                                                      replaced: .link(target: "/Applications/cmux.app/Contents/Resources/bin/cmux"))
        #expect(CLIInstallStrings.body(outcome).hasSuffix(
            "It replaced the previous link to /Applications/cmux.app/Contents/Resources/bin/cmux."))
    }

    @Test func createsTheBinFolderWhenMissing() async throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        _ = try await box.installer().install()
        #expect(box.installer().isInstalled())
    }

    @Test func refusesAMissingBundledCLIAndAFolderInTheWay() async throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        let missing = box.root.appendingPathComponent("nowhere/cmux")
        await #expect(throws: CLIPathInstaller.Failure.bundledCLIMissing(path: missing.path)) {
            try await CLIPathInstaller(destination: box.destination, source: missing, privileged: { _ in }).install()
        }
        try FileManager.default.createDirectory(at: box.destination, withIntermediateDirectories: true)
        await #expect(throws: CLIPathInstaller.Failure.destinationIsDirectory(path: box.destination.path)) {
            try await box.installer().install()
        }
    }

    @Test func aReadOnlyFolderGoesThroughTheAdministratorPrompt() async throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        try box.readOnlyParent()
        let ran = Ran()
        let installer = box.installer(privileged: Self.shell(unlocking: box.destination.deletingLastPathComponent(), ran: ran))
        let outcome = try await installer.install()
        #expect(outcome.usedAdministratorPrivileges)
        #expect(ran.count == 1)
        #expect(installer.isInstalled())

        try box.readOnlyParent()
        let removed = try await installer.uninstall()
        #expect(removed == .init(usedAdministratorPrivileges: true, destination: box.destination, removedExistingEntry: true))
        #expect(ran.count == 2)
        #expect(!installer.isInstalled())
    }

    @Test func uninstallReportsWhetherALinkWasThere() async throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        let none = try await box.installer().uninstall()
        #expect(!none.removedExistingEntry)
        _ = try await box.installer().install()
        let removed = try await box.installer().uninstall()
        #expect(removed.removedExistingEntry && !removed.usedAdministratorPrivileges)
        #expect(!FileManager.default.fileExists(atPath: box.destination.path))
    }

    @Test @MainActor func outcomesReadAsTheOldAppsSheets() {
        let outcome = CLIPathInstaller.InstallOutcome(usedAdministratorPrivileges: true, destination: URL(fileURLWithPath: "/usr/local/bin/cmux"),
                                                      source: URL(fileURLWithPath: "/Applications/cmux.app/Contents/Resources/bin/cmux"))
        #expect(CLIInstallStrings.body(outcome) == """
        Created symlink:

        /usr/local/bin/cmux -> /Applications/cmux.app/Contents/Resources/bin/cmux

        Administrator privileges were required to write to /usr/local/bin.
        """)
        #expect(CLIInstallStrings.message(CLIPathInstaller.Failure.destinationIsDirectory(path: "/x"))
            == "/x is a folder. Remove or rename it and try again.")
    }

    @Test @MainActor func bothActionsAreBound() {
        let registry = ActionBindingCoverageTests.boundServices().registry
        for id: ActionID in ["palette.installCLI", "palette.uninstallCLI"] {
            #expect(registry.isBound(id))
            #expect(registry.unavailableReason(for: id) == nil)
        }
    }
}
