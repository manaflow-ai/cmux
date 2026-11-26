@testable import CmuxSudoBroker
import Foundation
import Testing

/// Exercises the real Security.framework path against an ad-hoc signed throwaway bundle.
@Suite("Sudo bundle signature checker", .timeLimit(.minutes(1)))
struct SudoCodeSignatureCheckerTests {
    @Test("Sealed digest is read only from a validated bundle")
    func sealedDigestRequiresValidSeal() throws {
        let bundle = try AdHocBundle()
        defer { bundle.remove() }
        let checker = SystemSudoCodeSignatureChecker()

        let digest = try checker.sealedResourceDigest(
            bundleURL: bundle.url,
            requirement: nil,
            resourcePath: "Resources/bin/setup-pam-tid.sh"
        )
        #expect(SudoSHA256.hex(digest: digest) == SudoSHA256.hex(bundle.scriptBytes))

        #expect(throws: SudoCodeSignatureError.self) {
            try checker.sealedResourceDigest(
                bundleURL: bundle.url,
                requirement: SudoCodeSigningRequirement.developerID(teamIdentifier: "7WLXT3NR37"),
                resourcePath: "Resources/bin/setup-pam-tid.sh"
            )
        }
        #expect(throws: SudoCodeSignatureError.resourceNotSealed) {
            try checker.sealedResourceDigest(
                bundleURL: bundle.url,
                requirement: nil,
                resourcePath: "Resources/bin/missing"
            )
        }

        try Data("echo swapped\n".utf8).write(to: bundle.scriptURL)
        #expect(throws: SudoCodeSignatureError.self) {
            try checker.sealedResourceDigest(
                bundleURL: bundle.url,
                requirement: nil,
                resourcePath: "Resources/bin/setup-pam-tid.sh"
            )
        }
    }
}

private struct AdHocBundle {
    let root: URL
    let url: URL
    let scriptURL: URL
    let scriptBytes = Data("#!/bin/bash\necho sealed\n".utf8)

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-sudo-sig-\(UUID().uuidString)", isDirectory: true)
        url = root.appendingPathComponent("Fixture.app", isDirectory: true)
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        let bin = contents.appendingPathComponent("Resources/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: "/usr/bin/true"),
            to: macOS.appendingPathComponent("Fixture")
        )
        scriptURL = bin.appendingPathComponent("setup-pam-tid.sh")
        try scriptBytes.write(to: scriptURL)
        let plist: [String: Any] = [
            "CFBundleExecutable": "Fixture",
            "CFBundleIdentifier": "dev.cmux.sudo-signature-fixture",
            "CFBundlePackageType": "APPL",
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let codesign = Process()
        codesign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        codesign.arguments = ["--force", "--sign", "-", url.path]
        codesign.standardOutput = FileHandle.nullDevice
        codesign.standardError = FileHandle.nullDevice
        try codesign.run()
        codesign.waitUntilExit()
        guard codesign.terminationStatus == 0 else {
            throw CocoaError(.executableLoad)
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
