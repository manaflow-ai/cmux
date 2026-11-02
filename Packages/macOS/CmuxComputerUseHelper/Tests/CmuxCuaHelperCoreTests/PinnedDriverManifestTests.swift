// SPDX-License-Identifier: GPL-3.0-or-later
@testable import CmuxCuaHelperCore
import Foundation
import Testing

/// The pinned upstream driver (scripts/cmux-next/cua-driver-sdk.pin.json,
/// b0968e1) accepts the exact driver options and `ask` manifests the worker
/// writes: its parsers deny unknown fields, so a wrong key fails here, not in
/// a person's session. Needs no Accessibility: it creates the driver and
/// sessions, and calls nothing that touches an app. The SDK comes from
/// ensure-cua-pinned-asset.sh (its cache, CMUX_CUA_ASSET_FILE, the fleet
/// artifact store or R2); where none has it the test is disabled and says why.
@Suite(.serialized) struct PinnedDriverManifestTests {
    /// The pinned SDK tarball, or nil where it cannot be fetched.
    static let sdkTarball: String? = {
        guard let text = try? run("/bin/bash", [repo.appending(path: "scripts/cmux-next/ensure-cua-pinned-asset.sh").path,
                                               repo.appending(path: "scripts/cmux-next/cua-driver-sdk.pin.json").path,
                                               "--optional"]) else { return nil }
        let path = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }()

    static let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test(.timeLimit(.minutes(5)),
          .enabled(if: PinnedDriverManifestTests.sdkTarball != nil, "the pinned Cua Driver SDK is not reachable here (no cached copy, no store copy, no R2 read credentials)"))
    func thePinnedDriverAcceptsTheAskCeilingAndSessionManifests() throws {
        let library = try Self.pinnedLibrary()
        HelperEnvironment(helperBundleID: "com.cmuxterm.cua.tests").apply()
        let store = try SessionFixture.store()
        defer { try? FileManager.default.removeItem(atPath: store.directory) }
        let configuration = ComputerUseConfiguration(mode: .ask, client: "com.cmuxterm.app.debug.tests", machine: "fleet")
        let runtime = try CuaDriverRuntime(libraryPath: library, configuration: configuration,
                                           manifests: ManifestStoreLocation(directory: store.directory))
        let inventory = try runtime.inventory()
        let tools = CapabilityManifest.allowedTools(inventory: inventory)
        print("pinned inventory: \(tools.count) manifest tools: \(tools.joined(separator: ","))")
        #expect(tools.contains("click") && tools.contains("list_apps"))
        #expect(!tools.contains("run_script") && !tools.contains("replay_trajectory"))

        // Admission: the session manifest with no app.
        let broker = AppApprovalBroker(client: configuration.client, machine: configuration.machine)
        let consent = MachineConsentTests.ScriptedAuthority()
        consent.set(MachineConsentStatus(consentRequired: false, screen: false, control: false))
        let sessions = ComputerUseSessions(
            driver: runtime, configuration: configuration, broker: broker, gate: ConsentGate(authority: consent),
            targetGuard: CuaTargetGuard(policy: CuaTargetPolicy(), resolver: SessionFixture.Resolver()),
            manifests: store)
        let session = try sessions.openSession()
        defer { session.close() }

        // A grown manifest (bundle id apps) and a session close to its end of life.
        for (apps, lifetime) in [([ApprovalApp(bundleID: "com.apple.TextEdit", name: "TextEdit"),
                                   ApprovalApp(bundleID: "com.apple.Safari", name: "Safari")], 28800), ([], 90)] {
            let manifest = CapabilityManifest(tools: tools, apps: apps, expiresAfterSeconds: lifetime,
                                              idleTimeoutSeconds: ComputerUseConfiguration.idleSeconds)
            let path = try store.write(manifest.data, name: "grown-\(lifetime).json")
            defer { store.remove(path) }
            let handle = try runtime.createSession(options: configuration.sessionOptions(
                publicSession: "cmux-tests-\(lifetime)", lifetimeSeconds: lifetime, manifestPath: path))
            handle.destroy()
        }

        // The parser is strict: an unknown key is refused, so the passes above are meaningful.
        var wrong = try #require(HelperWire.object(CapabilityManifest(tools: tools, apps: [], expiresAfterSeconds: 60,
                                                                      idleTimeoutSeconds: 60).data))
        wrong["resources"] = ["apps": [], "desktop": ["display": false, "screens": true]]
        let wrongPath = try store.write(try CanonicalJSON.encode(wrong), name: "wrong.json")
        defer { store.remove(wrongPath) }
        #expect(throws: ToolError.self) {
            try runtime.createSession(options: configuration.sessionOptions(
                publicSession: "cmux-tests-wrong", lifetimeSeconds: 60, manifestPath: wrongPath))
        }
        // Above the ceiling: a standard session under the ask ceiling.
        #expect(throws: ToolError.self) {
            try runtime.createSession(options: ComputerUseConfiguration(mode: .standard, client: "c", machine: "m")
                .sessionOptions(publicSession: "cmux-tests-standard", lifetimeSeconds: 60, manifestPath: nil))
        }
    }

    /// The pinned SDK, fetched and unpacked; its dylib path.
    static func pinnedLibrary() throws -> String {
        let tarball = try #require(sdkTarball)
        let directory = FileManager.default.temporaryDirectory.appending(path: "cua-sdk-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = try run("/usr/bin/tar", ["-xzf", tarball, "-C", directory.path])
        let library = directory.appending(path: "cua-driver-sdk-macos-arm64/lib/libcua_driver_sdk.dylib").path
        try #require(FileManager.default.fileExists(atPath: library), "the SDK tarball has its dylib")
        return library
    }

    private static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ToolError("\(executable) \(arguments.joined(separator: " ")) failed")
        }
        return text
    }
}
