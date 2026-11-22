import Foundation
import Testing
@testable import CmuxNextDaemon

/// The app writes the "last opened app" pointer at launch, so a `cmux` shim
/// outside the app runs this app's CLI (plans/cmux-next/version-skew.md,
/// step 1). Lawrence's shim fell back to an older installed CLI because only
/// `reload.sh` wrote its pointer, and a fleet build opened through the Tag
/// Opener never runs it.
@Suite struct LastAppCLIPointerTests {
    @Test func publishWritesTheBundledCLIPathAtomicallyWithOwnerOnlyAccess() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let cli = try home.makeExecutable("Apps/cmux DEV t.app/Contents/Resources/bin/cmux")
        let pointer = LastAppCLIPointer(userHome: home.url)

        #expect(pointer.publish(cliPath: cli))

        let file = home.url.appendingPathComponent("Library/Application Support/cmux/last-app-cli")
        #expect(pointer.file == file)
        #expect(try String(contentsOf: file, encoding: .utf8) == cli + "\n")
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
        // Renamed into place: no temporary file is left next to it.
        let names = try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)
        #expect(names == ["last-app-cli"])
    }

    @Test func aLaterLaunchReplacesThePointer() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let first = try home.makeExecutable("Apps/cmux DEV a.app/Contents/Resources/bin/cmux")
        let second = try home.makeExecutable("Apps/cmux DEV b.app/Contents/Resources/bin/cmux")
        let pointer = LastAppCLIPointer(userHome: home.url)
        #expect(pointer.publish(cliPath: first))
        #expect(pointer.publish(cliPath: second))
        #expect(try String(contentsOf: pointer.file, encoding: .utf8) == second + "\n")
    }

    @Test func aMissingOrRelativeCLIIsNeverPublished() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let pointer = LastAppCLIPointer(userHome: home.url)
        #expect(!pointer.publish(cliPath: home.url.appendingPathComponent("nope/cmux").path))
        #expect(!pointer.publish(cliPath: "cmux"))
        #expect(!FileManager.default.fileExists(atPath: pointer.file.path))
    }

    @Test func aSymlinkInPlaceOfThePointerIsReplacedNotFollowed() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let cli = try home.makeExecutable("Apps/cmux DEV t.app/Contents/Resources/bin/cmux")
        let pointer = LastAppCLIPointer(userHome: home.url)
        let victim = home.url.appendingPathComponent("victim")
        try "keep\n".write(to: victim, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: pointer.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: pointer.file, withDestinationURL: victim)

        #expect(pointer.publish(cliPath: cli))
        #expect(try String(contentsOf: victim, encoding: .utf8) == "keep\n")
        let type = try FileManager.default.attributesOfItem(atPath: pointer.file.path)[.type] as? FileAttributeType
        #expect(type == .typeRegular)
    }

    @Test func onlyAUserVisibleLaunchPublishes() {
        #expect(LastAppCLIPointer.shouldPublish(environment: [:]))
        #expect(!LastAppCLIPointer.shouldPublish(environment: ["CMUX_NEXT_NO_ACTIVATE": "1"]))
    }
}

private struct TemporaryHome {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-last-app-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func makeExecutable(_ relative: String) throws -> String {
        let file = url.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return file.path
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
