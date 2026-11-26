import Foundation
import Testing
@testable import CmuxComputerUse

/// A build installs only a Developer ID signed "cmux Computer Use" helper.
/// An ad-hoc copy (what a tagged dev build bundles) is never installed or
/// launched: a Screen Recording grant to it replaces the release helper's row.
@MainActor
struct ComputerUseHelperTrustTests {
    /// The real signature check with no installed release apps.
    private static let realTrustWithoutReleaseApps = ComputerUseHelperTrust(
        isSigned: ComputerUseHelperTrust.satisfiesRequirement,
        installedCandidates: { [] }
    )

    @Test func anAdHocHelperFailsTheSignatureCheck() throws {
        let fixture = try HelperBundleFixture()
        defer { fixture.remove() }
        let helper = try Self.adHocHelper(at: fixture.root.appendingPathComponent("adhoc/cmux Computer Use.app"))
        #expect(!ComputerUseHelperTrust.satisfiesRequirement(helper))
        #expect(!ComputerUseHelperTrust.satisfiesRequirement(fixture.root.appendingPathComponent("missing.app")))
    }

    @Test func anUnsignedBuildInstallsNothingAndReportsUnavailable() async throws {
        let fixture = try HelperRuntimeFixture()
        defer { fixture.files.remove() }
        let runtime = ComputerUseRuntimeService(
            bundle: fixture.bundle, paths: fixture.paths, isDisabledByPolicy: { false },
            helperTrust: Self.realTrustWithoutReleaseApps
        )
        defer { runtime.stopForTermination() }

        #expect(await runtime.ensureStandaloneHelperInstalled() == nil)
        #expect(runtime.helperAppURL == nil)
        #expect(runtime.helperUnavailableInThisBuild)
        #expect(try Self.applicationNames(in: fixture.paths.installedHelperDirectoryURL).isEmpty)
    }

    @Test func anAdHocInstalledCandidateIsRefused() async throws {
        let fixture = try HelperRuntimeFixture()
        defer { fixture.files.remove() }
        let candidate = try Self.adHocHelper(at: fixture.files.root.appendingPathComponent("Other/cmux Computer Use.app"))
        let runtime = ComputerUseRuntimeService(
            bundle: fixture.bundle, paths: fixture.paths, isDisabledByPolicy: { false },
            helperTrust: ComputerUseHelperTrust(
                isSigned: ComputerUseHelperTrust.satisfiesRequirement,
                installedCandidates: { [candidate] }
            )
        )
        defer { runtime.stopForTermination() }

        #expect(await runtime.ensureStandaloneHelperInstalled() == nil)
        #expect(runtime.helperUnavailableInThisBuild)
        #expect(try Self.applicationNames(in: fixture.paths.installedHelperDirectoryURL).isEmpty)
    }

    @Test func aSignedInstalledHelperIsUsedWhenTheNestedOneIsUnsigned() async throws {
        let fixture = try HelperRuntimeFixture()
        defer { fixture.files.remove() }
        let release = fixture.files.root.appendingPathComponent("Release/cmux Computer Use.app")
        try FileManager.default.createDirectory(at: release.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture.files.bundle, to: release)
        let releaseExecutable = release.appendingPathComponent("Contents/MacOS/cmux-cua")
        try Data("release helper".utf8).write(to: releaseExecutable)
        // Every helper is signed except this dev build's own nested one
        // (the staged copy of the release helper is re-checked too).
        let nestedPath = fixture.nestedHelper.standardizedFileURL.path
        let runtime = ComputerUseRuntimeService(
            bundle: fixture.bundle, paths: fixture.paths, isDisabledByPolicy: { false },
            helperTrust: ComputerUseHelperTrust(
                isSigned: { $0.standardizedFileURL.path != nestedPath },
                installedCandidates: { [release] }
            )
        )
        defer { runtime.stopForTermination() }

        let installed = try #require(await runtime.ensureStandaloneHelperInstalled())
        #expect(!runtime.helperUnavailableInThisBuild)
        let copied = try Data(contentsOf: installed.appendingPathComponent("Contents/MacOS/cmux-cua"))
        #expect(copied == Data("release helper".utf8))
    }

    @Test func aStaleAdHocInstalledCopyIsRemoved() async throws {
        let fixture = try HelperRuntimeFixture()
        defer { fixture.files.remove() }
        let destination = fixture.paths.installedHelperAppURL
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: fixture.files.bundle, to: destination)
        let runtime = ComputerUseRuntimeService(
            bundle: fixture.bundle, paths: fixture.paths, isDisabledByPolicy: { false },
            helperTrust: Self.realTrustWithoutReleaseApps
        )
        defer { runtime.stopForTermination() }

        #expect(await runtime.ensureStandaloneHelperInstalled() == nil)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func releaseCandidatesPreferNightlyAndListOnlyInstalledApps() {
        let home = URL(fileURLWithPath: "/Users/someone")
        let candidates = ComputerUseHelperTrust.releaseCandidates(home: home)
        #expect(candidates.first?.path == "/Applications/cmux NIGHTLY.app/Contents/Library/cmux Computer Use.app")
        #expect(candidates.contains { $0.path == "/Users/someone/Applications/cmux RC.app/Contents/Library/cmux Computer Use.app" })
        #expect(candidates.allSatisfy { $0.path.hasPrefix("/Applications/") || $0.path.hasPrefix("/Users/someone/Applications/") })
        #expect(Set(candidates.map(\.path)).count == candidates.count)
    }

    /// Release builds are unchanged: a signed nested helper is installed even
    /// when an installed release helper is also trusted.
    @Test func aSignedNestedHelperWinsOverInstalledHelpers() async throws {
        let fixture = try HelperRuntimeFixture()
        defer { fixture.files.remove() }
        let other = fixture.files.root.appendingPathComponent("Release/cmux Computer Use.app")
        try FileManager.default.createDirectory(at: other.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture.files.bundle, to: other)
        try Data("release helper".utf8).write(to: other.appendingPathComponent("Contents/MacOS/cmux-cua"))
        let runtime = ComputerUseRuntimeService(
            bundle: fixture.bundle, paths: fixture.paths, isDisabledByPolicy: { false },
            helperTrust: ComputerUseHelperTrust(isSigned: { _ in true }, installedCandidates: { [other] })
        )
        defer { runtime.stopForTermination() }

        let installed = try #require(await runtime.ensureStandaloneHelperInstalled())
        let copied = try Data(contentsOf: installed.appendingPathComponent("Contents/MacOS/cmux-cua"))
        #expect(copied == Data("helper".utf8))
    }

    /// A Developer ID copy already at the helper path stays and is used when
    /// no source is available any more (the release app was removed).
    @Test func aTrustedInstalledCopyIsKeptWithoutASource() async throws {
        let fixture = try HelperRuntimeFixture()
        defer { fixture.files.remove() }
        let destination = fixture.paths.installedHelperAppURL
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: fixture.files.bundle, to: destination)
        let destinationPath = destination.standardizedFileURL.path
        let runtime = ComputerUseRuntimeService(
            bundle: fixture.bundle, paths: fixture.paths, isDisabledByPolicy: { false },
            helperTrust: ComputerUseHelperTrust(
                isSigned: { $0.standardizedFileURL.path == destinationPath },
                installedCandidates: { [] }
            )
        )
        defer { runtime.stopForTermination() }

        #expect(await runtime.ensureStandaloneHelperInstalled()?.standardizedFileURL.path == destinationPath)
        #expect(!runtime.helperUnavailableInThisBuild)
        #expect(FileManager.default.fileExists(atPath: destination.path))
    }

    /// A helper with the real bundle identifier, signed ad hoc the way a
    /// tagged dev build signs it (identifier requirement, no certificate).
    private static func adHocHelper(at app: URL) throws -> URL {
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: macOS.appendingPathComponent("cmux-cua"))
        let plist: [String: Any] = [
            "CFBundleIdentifier": ComputerUseHelperTrust.bundleIdentifier,
            "CFBundleExecutable": "cmux-cua",
            "CFBundlePackageType": "APPL",
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        let codesign = Process()
        codesign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        codesign.arguments = [
            "--force", "--sign", "-", "--timestamp=none",
            "--identifier", ComputerUseHelperTrust.bundleIdentifier,
            "--requirements", "=designated => identifier \"\(ComputerUseHelperTrust.bundleIdentifier)\"",
            app.path,
        ]
        codesign.standardOutput = FileHandle.nullDevice
        codesign.standardError = FileHandle.nullDevice
        try codesign.run()
        codesign.waitUntilExit()
        try #require(codesign.terminationStatus == 0, "codesign could not sign the test helper")
        return app
    }

    private static func applicationNames(in directory: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".app") }.sorted()
    }
}
