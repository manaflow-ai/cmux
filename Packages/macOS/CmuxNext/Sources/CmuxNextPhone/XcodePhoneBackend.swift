public import Foundation

/// Simulators through `xcrun simctl` and real iPhones through `xcrun
/// devicectl`: both ship with Xcode, so cmux bundles nothing.
///
/// Simulator: boot, screenshot, video (`.mov`), log stream, open URL,
/// clipboard. Real device: screenshot and video (`.mp4`). Touch, keys and the
/// live frame stream come in later phases.
public struct XcodePhoneBackend: PhoneBackend {
    private let runner: any PhoneCommandRunning

    public init(runner: any PhoneCommandRunning = PhoneProcessRunner()) {
        self.runner = runner
    }

    public func devices() async throws -> [PhoneDevice] {
        let sims = try await checked(["simctl", "list", "devices", "-j"], name: "simctl list")
        var phones = try SimctlDeviceList().parse(sims.stdout)
        // A Mac without paired devices (or without devicectl) still lists simulators.
        if let real = try? await runner.run(["devicectl", "list", "devices", "--json-output", "-", "--quiet"], deadline: .seconds(20)),
           real.status == 0, let devices = try? DevicectlDeviceList().parse(real.stdout) {
            phones.append(contentsOf: devices)
        }
        return phones
    }

    public func capabilities(for device: PhoneDevice) -> PhoneCapabilities {
        switch device.mode {
        case .simulator: [.boot, .screenshot, .recordVideo, .deviceLog, .openURL, .pasteboard]
        case .device: [.screenshot, .recordVideo]
        case .virtualMachine: []
        }
    }

    public func boot(_ id: PhoneDeviceID) async throws {
        try requireSimulator(id, "boot")
        let result = try await runner.run(["simctl", "boot", id.raw], deadline: .seconds(120))
        // Booting a booted simulator is success for us.
        guard result.status == 0 || result.stderr.contains("current state: Booted") else {
            throw PhoneError.commandFailed(command: "simctl boot", status: result.status, stderr: result.stderr)
        }
    }

    public func shutdown(_ id: PhoneDeviceID) async throws {
        try requireSimulator(id, "shut down")
        let result = try await runner.run(["simctl", "shutdown", id.raw], deadline: .seconds(60))
        guard result.status == 0 || result.stderr.contains("current state: Shutdown") else {
            throw PhoneError.commandFailed(command: "simctl shutdown", status: result.status, stderr: result.stderr)
        }
    }

    public func screenshot(_ id: PhoneDeviceID, to file: URL) async throws {
        switch id.mode {
        case .simulator:
            _ = try await checked(["simctl", "io", id.raw, "screenshot", "--type=png", file.path], name: "simctl screenshot")
        case .device:
            _ = try await checked(["devicectl", "device", "capture", "screenshot", "--device", id.raw,
                                   "--destination", file.path, "--quiet"], name: "devicectl screenshot", deadline: .seconds(60))
        case .virtualMachine:
            throw PhoneError.unsupported(mode: id.mode, what: "screenshot")
        }
    }

    public func videoExtension(for id: PhoneDeviceID) -> String {
        id.mode == .device ? "mp4" : "mov"
    }

    public func startVideo(_ id: PhoneDeviceID, to file: URL) async throws -> any PhoneRunningCommand {
        switch id.mode {
        case .simulator:
            // h264 so the clip plays everywhere it is sent (hevc is simctl's default).
            try await runner.start(["simctl", "io", id.raw, "recordVideo", "--codec=h264", "--force", file.path], stdoutFile: nil)
        case .device:
            try await runner.start(["devicectl", "device", "capture", "screen-record", "--device", id.raw,
                                    "--destination", file.path, "--codec", "h264", "--quiet"], stdoutFile: nil)
        case .virtualMachine:
            throw PhoneError.unsupported(mode: id.mode, what: "recording")
        }
    }

    public func startLog(_ id: PhoneDeviceID, to file: URL) async throws -> (any PhoneRunningCommand)? {
        guard id.mode == .simulator else { return nil }
        return try await runner.start(["simctl", "spawn", id.raw, "log", "stream", "--style", "ndjson", "--level", "info"],
                                      stdoutFile: file)
    }

    public func send(_ input: PhoneInput, to id: PhoneDeviceID) async throws {
        guard id.mode == .simulator else { throw PhoneError.unsupported(mode: id.mode, what: input.kind) }
        switch input {
        case .openURL(let url):
            _ = try await checked(["simctl", "openurl", id.raw, url.absoluteString], name: "simctl openurl")
        case .pasteboard(let text):
            let result = try await runner.run(["simctl", "pbcopy", id.raw], stdin: Data(text.utf8), deadline: .seconds(15))
            guard result.status == 0 else {
                throw PhoneError.commandFailed(command: "simctl pbcopy", status: result.status, stderr: result.stderr)
            }
        case .tap, .swipe, .text, .button:
            throw PhoneError.unsupported(mode: id.mode, what: input.kind)
        }
    }

    private func requireSimulator(_ id: PhoneDeviceID, _ what: String) throws {
        guard id.mode == .simulator else { throw PhoneError.unsupported(mode: id.mode, what: what) }
    }

    private func checked(_ arguments: [String], name: String, deadline: Duration = .seconds(30)) async throws -> PhoneCommandResult {
        let result = try await runner.run(arguments, stdin: nil, deadline: deadline)
        guard result.status == 0 else { throw PhoneError.commandFailed(command: name, status: result.status, stderr: result.stderr) }
        return result
    }
}
