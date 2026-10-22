public import Foundation

/// Finds the next iOS simulator setup step a Mac needs, and runs the two
/// steps cmux can do itself (download the iOS runtime, create an iPhone).
///
/// It never runs `xcrun` before ``XcodeLocator`` found an Xcode (see there),
/// and it asks only read-only questions (`simctl list`), so checking again is
/// always safe: the setup screen checks when the app becomes active again,
/// for example after the user installed Xcode from the App Store.
///
/// ```swift
/// let check = PhoneSetupCheck(xcode: XcodeLocator(), runner: PhoneProcessRunner(developerDirectory: { XcodeLocator().developerDirectory() }))
/// let status = await check.status()   // .installXcode on a new Mac
/// ```
public struct PhoneSetupCheck: Sendable {
    private let xcode: XcodeLocator
    private let runner: any PhoneCommandRunning & PhoneStreamingRunning

    /// - Parameters:
    ///   - xcode: finds Xcode without running anything.
    ///   - runner: runs `xcrun` tools under the found Xcode.
    public init(xcode: XcodeLocator, runner: any PhoneCommandRunning & PhoneStreamingRunning) {
        self.xcode = xcode
        self.runner = runner
    }

    /// The first step this Mac still needs.
    public func status() async -> PhoneSetupStatus {
        guard xcode.developerDirectory() != nil else {
            return PhoneSetupStatus(step: .installXcode, hasOnlyCommandLineTools: xcode.hasOnlyCommandLineTools)
        }
        let app = xcode.xcodeApp()
        // An Xcode that was never opened refuses to run its tools (license) or lacks the
        // components simctl needs (first launch); opening Xcode once fixes both.
        guard let listed = try? await runner.run(["simctl", "list", "runtimes", "-j"], deadline: .seconds(30)), listed.status == 0,
              let runtimes = try? SimctlRuntimeList().parse(listed.stdout) else {
            return PhoneSetupStatus(step: .finishXcode, xcodeApp: app)
        }
        if let firstLaunch = try? await runner.run(["xcodebuild", "-checkFirstLaunchStatus"], deadline: .seconds(30)),
           firstLaunch.status != 0 {
            return PhoneSetupStatus(step: .finishXcode, xcodeApp: app)
        }
        guard let newest = runtimes.first else { return PhoneSetupStatus(step: .downloadIOS, xcodeApp: app) }
        guard let devices = try? await runner.run(["simctl", "list", "devices", "-j"], deadline: .seconds(30)), devices.status == 0,
              let phones = try? SimctlDeviceList().parse(devices.stdout) else {
            return PhoneSetupStatus(step: .finishXcode, xcodeApp: app, runtime: newest)
        }
        let usable = phones.contains(where: \.isUsable)
        return PhoneSetupStatus(step: usable ? .ready : .createIPhone, xcodeApp: app, runtime: newest)
    }

    /// Downloads and installs the newest iOS simulator runtime (about 8 GB),
    /// reporting progress as the tool prints it. Throws when it fails; the
    /// caller shows ``PhoneErrorText`` for it.
    public func downloadIOS(progress: @escaping @MainActor @Sendable (PhoneSetupProgress) -> Void) async throws {
        var current = PhoneSetupProgress()
        for try await event in runner.stream(["xcodebuild", "-downloadPlatform", "iOS"]) {
            switch event {
            case .output(let text):
                let next = current.reading(text)
                if next != current {
                    current = next
                    await progress(next)
                }
            case .exited(let status, let stderr):
                guard status == 0 else {
                    throw PhoneError.commandFailed(command: "xcodebuild -downloadPlatform iOS", status: status, stderr: stderr)
                }
            }
        }
    }

    /// Creates the suggested iPhone (``SimctlRuntime/suggestedIPhone``) on the newest iOS runtime and returns it.
    public func createIPhone() async throws -> PhoneDeviceID {
        let listed = try await runner.run(["simctl", "list", "runtimes", "-j"], deadline: .seconds(30))
        guard listed.status == 0, let runtime = try SimctlRuntimeList().parse(listed.stdout).first else {
            throw PhoneError.missingTool(.xcode)
        }
        guard let type = runtime.suggestedIPhone else { throw PhoneError.unreadable(what: "the iPhone models of \(runtime.name)") }
        let made = try await runner.run(["simctl", "create", type.name, type.identifier, runtime.identifier], deadline: .seconds(60))
        guard made.status == 0 else { throw PhoneError.commandFailed(command: "simctl create", status: made.status, stderr: made.stderr) }
        let udid = String(decoding: made.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !udid.isEmpty else { throw PhoneError.unreadable(what: "the new simulator's id") }
        return PhoneDeviceID(mode: .simulator, raw: udid)
    }
}
