public import Foundation

/// Simulators through `xcrun simctl` and real iPhones through `xcrun
/// devicectl`: both ship with Xcode, so cmux bundles nothing.
///
/// Simulator: boot, screenshot, video (`.mov`), log stream, open URL,
/// clipboard, appearance, location, locale, install and launch; with a
/// ``SimulatorHIDSending`` also touches, typing and hardware buttons. Real
/// device: screenshot and video (`.mp4`).
public struct XcodePhoneBackend: PhoneBackend {
    private let runner: any PhoneCommandRunning
    private let hid: (any SimulatorHIDSending)?

    /// - Parameter hid: the simulator input path; nil leaves touch, keys and buttons off.
    public init(runner: any PhoneCommandRunning = PhoneProcessRunner(), hid: (any SimulatorHIDSending)? = nil) {
        self.runner = runner
        self.hid = hid
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
        case .simulator:
            PhoneCapabilities([.boot, .screenshot, .recordVideo, .deviceLog, .openURL, .pasteboard, .appearance, .location, .locale, .apps])
                .union(hid == nil ? [] : [.touch, .keyboard, .buttons, .liveScreen])
        case .device: [.screenshot, .recordVideo]
        case .virtualMachine, .emulator, .androidDevice: []
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
        case .virtualMachine, .emulator, .androidDevice:
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
        case .virtualMachine, .emulator, .androidDevice:
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
        case .appearance(let appearance):
            _ = try await checked(["simctl", "ui", id.raw, "appearance", appearance.rawValue], name: "simctl ui appearance")
        case .location(let latitude, let longitude):
            _ = try await checked(["simctl", "location", id.raw, "set", "\(latitude),\(longitude)"], name: "simctl location")
        case .locale(let identifier):
            // Apps read the global domain at launch, so a relaunched app shows the new language.
            let language = identifier.split(whereSeparator: { $0 == "_" || $0 == "-" }).first.map(String.init) ?? identifier
            _ = try await checked(["simctl", "spawn", id.raw, "defaults", "write", "-g", "AppleLanguages", "-array", language],
                                  name: "simctl defaults")
            _ = try await checked(["simctl", "spawn", id.raw, "defaults", "write", "-g", "AppleLocale", "-string", identifier],
                                  name: "simctl defaults")
        case .install(let app):
            _ = try await checked(["simctl", "install", id.raw, app.path], name: "simctl install", deadline: .seconds(180))
        case .launch(let bundleID):
            _ = try await checked(["simctl", "launch", id.raw, bundleID], name: "simctl launch", deadline: .seconds(60))
        case .tap(let point):
            try input.validate()
            let hid = try requireHID(input)
            try await hid.send(touches: try await gesture(id, hid).tap(point), to: id.raw)
        case .swipe(let from, let to, let seconds):
            try input.validate()
            let hid = try requireHID(input)
            try await hid.send(touches: try await gesture(id, hid).swipe(from: from, to: to, seconds: seconds), to: id.raw)
        case .text(let text):
            let hid = try requireHID(input)
            if let strokes = PhoneKeyboard().strokes(for: text) {
                try await hid.send(keys: strokes, to: id.raw)
            } else {
                // No US key for some character: paste it, which types any script.
                try await send(.pasteboard(text), to: id)
                try await hid.send(keys: [PhoneKeyStroke(usage: 0x19, command: true)], to: id.raw)
            }
        case .softwareKeyboard:
            try await requireHID(input).toggleSoftwareKeyboard(on: id.raw)
        case .button(let button):
            let hid = try requireHID(input)
            guard let usage = Self.consumerUsage(button) else {
                throw PhoneError.unsupported(mode: id.mode, what: "the \(button.rawValue) button")
            }
            try await hid.press(page: 0x0C, usage: usage, on: id.raw)
        }
    }

    /// The simulator's current appearance (`simctl ui <udid> appearance` with no value prints it).
    public func appearance(_ id: PhoneDeviceID) async throws -> PhoneAppearance {
        try requireSimulator(id, "appearance")
        let out = try await checked(["simctl", "ui", id.raw, "appearance"], name: "simctl ui appearance").stdout
        let text = String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let appearance = PhoneAppearance(rawValue: text) else { throw PhoneError.unreadable(what: "the appearance") }
        return appearance
    }

    public func screenPoints(_ id: PhoneDeviceID) async throws -> PhonePoint {
        guard id.mode == .simulator, let hid else { throw PhoneError.unsupported(mode: id.mode, what: "touch") }
        let size = try await hid.screenSize(of: id.raw)
        return PhonePoint(x: size.width, y: size.height)
    }

    public func logCommand(_ id: PhoneDeviceID) async throws -> [String] {
        guard id.mode == .simulator else { throw PhoneError.unsupported(mode: id.mode, what: "logs") }
        return ["/usr/bin/xcrun", "simctl", "spawn", id.raw, "log", "stream", "--style", "compact", "--level", "info"]
    }

    private func requireHID(_ input: PhoneInput) throws -> any SimulatorHIDSending {
        guard let hid else { throw PhoneError.unsupported(mode: .simulator, what: input.kind) }
        return hid
    }

    private func gesture(_ id: PhoneDeviceID, _ hid: any SimulatorHIDSending) async throws -> PhoneGesture {
        let size = try await hid.screenSize(of: id.raw)
        return PhoneGesture(screen: PhonePoint(x: size.width, y: size.height))
    }

    /// iOS hardware buttons as HID consumer-page usages (the Xcode 27 DTUHID
    /// usages; the legacy Indigo path maps them back). Nil for Android-only buttons.
    static func consumerUsage(_ button: PhoneButton) -> UInt32? {
        switch button {
        case .home: 0x40
        case .lock: 0x30
        case .siri: 0xCF
        case .volumeUp: 0xE9
        case .volumeDown: 0xEA
        case .back, .appSwitch: nil
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
