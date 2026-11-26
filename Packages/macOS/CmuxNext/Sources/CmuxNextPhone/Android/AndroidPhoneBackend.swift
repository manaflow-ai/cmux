public import Foundation

/// Android emulators (AVDs) and USB phones through the SDK's `adb` and
/// `emulator` (plans/cmux-next/simulators-DESIGN.md). Points are
/// density-independent pixels (dp), so a tap at a frame from
/// ``accessibilityTree(_:)`` hits that element on any screen density.
///
/// An actor because it remembers which `adb` serial runs each AVD and each
/// screen's density between calls.
public actor AndroidPhoneBackend: PhoneBackend {
    public let sdk: AndroidSDK
    private let runner: any PhoneCommandRunning
    /// AVD name or USB serial (the id's raw value) -> adb serial, from the last list.
    private var serials: [String: String] = [:]
    /// adb serial -> pixels per dp, and the `wm density` output it was read from.
    private var densities: [String: (scale: Double, output: String)] = [:]

    /// - Parameters:
    ///   - sdk: the SDK whose tools run.
    ///   - runner: runs commands with the tool's absolute path first (``PhoneProcessRunner`` with no launcher).
    public init(sdk: AndroidSDK, runner: any PhoneCommandRunning = PhoneProcessRunner(launcher: nil)) {
        self.sdk = sdk
        self.runner = runner
    }

    public func devices() async throws -> [PhoneDevice] {
        let avds = try await checked([sdk.emulator, "-list-avds"], name: "emulator -list-avds").stdout
        let names = (try? PhoneRules.decode([String].self, "names", "avd_names", ["output": PhoneRules.text(avds)],
                                            what: "the AVD list")) ?? []
        let attached = AndroidDeviceList().parse(try await checked([sdk.adb, "devices", "-l"], name: "adb devices").stdout)
        var running: [PhoneDevice] = [], usb: [PhoneDevice] = []
        var found: [String: String] = [:]
        for entry in attached where entry.state == "device" {
            let release = try? await shell(entry.serial, ["getprop", "ro.build.version.release"])
            let version = "Android " + (release ?? "?")
            if entry.isEmulator {
                guard let avd = try? await avdName(entry.serial) else { continue }
                found[avd] = entry.serial
                running.append(PhoneDevice(id: PhoneDeviceID(mode: .emulator, raw: avd), name: Self.displayName(avd),
                                           model: entry.model ?? Self.displayName(avd), osVersion: version, state: .ready))
            } else {
                found[entry.serial] = entry.serial
                let model = Self.usbModel(entry)
                usb.append(PhoneDevice(id: PhoneDeviceID(mode: .androidDevice, raw: entry.serial), name: model,
                                       model: model, osVersion: version, state: .ready, transport: "usb"))
            }
        }
        serials = found
        let stopped = names.filter { found[$0] == nil }.map {
            PhoneDevice(id: PhoneDeviceID(mode: .emulator, raw: $0), name: Self.displayName($0), model: Self.displayName($0),
                        osVersion: "Android", state: .shutdown)
        }
        return running + usb + stopped
    }

    public nonisolated func capabilities(for device: PhoneDevice) -> PhoneCapabilities {
        var caps: PhoneCapabilities = [.screenshot, .recordVideo, .deviceLog, .openURL, .touch, .keyboard, .buttons,
                                       .appearance, .apps, .accessibility, .liveScreen]
        if device.mode == .emulator { caps.formUnion([.boot, .location, .rotate, .locale]) }
        return caps
    }

    public func boot(_ id: PhoneDeviceID) async throws {
        guard id.mode == .emulator else { throw PhoneError.unsupported(mode: id.mode, what: "boot") }
        if (try? await serial(id)) != nil { return }
        // Each emulator takes an even console port; adb names it emulator-<port>.
        guard let port = try? PhoneRules.decode(Int?.self, "port", "free_emulator_port", ["serials": Array(serials.values)],
                                                what: "the emulator ports") else {
            throw PhoneError.unsupported(mode: id.mode, what: "more than 64 running emulators")
        }
        // Headless: the phone tab draws the screen, so no emulator window opens.
        _ = try await runner.start([sdk.emulator, "-avd", id.raw, "-port", String(port), "-no-window", "-no-audio", "-no-boot-anim"],
                                   stdoutFile: nil)
        let serial = "emulator-\(port)"
        // The device-side loop is the documented boot signal (sys.boot_completed); adb has no event for it.
        let booted = try await runner.run([sdk.adb, "-s", serial, "wait-for-device", "shell",
                                           "while [ \"$(getprop sys.boot_completed)\" != 1 ]; do sleep 1; done"],
                                          stdin: nil, deadline: .seconds(300))
        guard booted.status == 0 else {
            throw PhoneError.commandFailed(command: "adb wait-for-device", status: booted.status, stderr: booted.stderr)
        }
        serials[id.raw] = serial
    }

    public func shutdown(_ id: PhoneDeviceID) async throws {
        guard id.mode == .emulator else { throw PhoneError.unsupported(mode: id.mode, what: "shut down") }
        let serial = try await serial(id)
        _ = try await checked([sdk.adb, "-s", serial, "emu", "kill"], name: "adb emu kill")
        serials[id.raw] = nil
    }

    public func screenshot(_ id: PhoneDeviceID, to file: URL) async throws {
        let serial = try await serial(id)
        let png = try await checked([sdk.adb, "-s", serial, "exec-out", "screencap", "-p"], name: "adb screencap").stdout
        guard !png.isEmpty else { throw PhoneError.unreadable(what: "the screenshot") }
        try png.write(to: file, options: .atomic)
    }

    public nonisolated func videoExtension(for id: PhoneDeviceID) -> String { "mp4" }

    public func startVideo(_ id: PhoneDeviceID, to file: URL) async throws -> any PhoneRunningCommand {
        let serial = try await serial(id)
        // Raw H.264 straight to the Mac file; SIGINT ends adb and the file is complete up to the last frame.
        return try await runner.start([sdk.adb, "-s", serial, "exec-out", "screenrecord", "--output-format=h264", "-"],
                                      stdoutFile: file)
    }

    public func startLog(_ id: PhoneDeviceID, to file: URL) async throws -> (any PhoneRunningCommand)? {
        let serial = try await serial(id)
        return try await runner.start([sdk.adb, "-s", serial, "logcat", "-v", "threadtime"], stdoutFile: file)
    }

    public func send(_ input: PhoneInput, to id: PhoneDeviceID) async throws {
        let serial = try await serial(id)
        // Pixels per dp matter to taps and swipes only; reading them costs a shell call.
        var scale = 1.0
        switch input {
        case .tap, .swipe: scale = try await density(serial)
        default: break
        }
        let calls: [AdbCall]
        do {
            calls = try PhoneRules.decode([AdbCall].self, "calls", "android_input_calls",
                                          ["input": Self.wire(input), "emulator": id.mode == .emulator, "scale": scale],
                                          what: "the adb calls")
        } catch let refusal as PhoneRules.Refusal where refusal.kind == "unsupported" {
            throw PhoneError.unsupported(mode: id.mode, what: input.kind)
        }
        for call in calls {
            try await run(serial, call.args, call.name, deadline: .seconds(call.deadlineSeconds))
        }
    }

    public func accessibilityTree(_ id: PhoneDeviceID) async throws -> PhoneElement {
        let serial = try await serial(id)
        let xml = try await checked([sdk.adb, "-s", serial, "exec-out", "uiautomator", "dump", "/dev/tty"], name: "adb uiautomator").stdout
        return try UIAutomatorTree(pixelsPerPoint: try await density(serial)).parse(xml)
    }

    public func screenPoints(_ id: PhoneDeviceID) async throws -> PhonePoint {
        let serial = try await serial(id)
        // "Physical size: 1080x2400" (an "Override size" line follows when set; the last wins).
        let size = try await shell(serial, ["wm", "size"])
        _ = try await density(serial)
        // wm size is the natural (portrait) size; screencap and taps follow the rotation.
        let rotation = try? await shell(serial, ["settings", "get", "system", "user_rotation"])
        var fields: [String: Any] = ["size_output": size, "density_output": densities[serial]?.output ?? ""]
        if let rotation { fields["rotation"] = rotation }
        let points = try PhoneRules.reply([String: Double].self, "screen_points", fields, what: "the screen size")
        guard let width = points["width"], let height = points["height"] else { throw PhoneError.unreadable(what: "the screen size") }
        return PhonePoint(x: width, y: height)
    }

    public func logCommand(_ id: PhoneDeviceID) async throws -> [String] {
        [sdk.adb, "-s", try await serial(id), "logcat", "-v", "color"]
    }

    /// The `adb` path and serial a live screen stream uses.
    public func streamTarget(_ id: PhoneDeviceID) async throws -> (adb: String, serial: String) {
        (sdk.adb, try await serial(id))
    }

    /// Rotates an emulator a quarter turn clockwise (the console's `rotate`).
    public func rotate(_ id: PhoneDeviceID) async throws {
        try await rotate(id, .right)
    }

    /// Rotates an emulator a quarter turn: the console's `rotate` turns clockwise, so left is three turns.
    public func rotate(_ id: PhoneDeviceID, _ direction: PhoneRotation) async throws {
        guard id.mode == .emulator else { throw PhoneError.unsupported(mode: id.mode, what: "rotate") }
        let serial = try await serial(id)
        for _ in 0..<(direction == .right ? 1 : 3) {
            try await run(serial, ["emu", "rotate"], "adb emu rotate")
        }
    }

    /// Whether night mode is on (`cmd uimode night` answers "Night mode: yes|no|auto"; auto reads as light).
    public func appearance(_ id: PhoneDeviceID) async throws -> PhoneAppearance {
        let text = try await shell(try await serial(id), ["cmd", "uimode", "night"])
        let dark = try PhoneRules.decode(Bool.self, "dark", "night_mode", ["output": text], what: "the night mode")
        return dark ? .dark : .light
    }

    // MARK: - Helpers

    /// The adb serial of a running phone, listing again once when unknown.
    func serial(_ id: PhoneDeviceID) async throws -> String {
        guard id.mode.isAndroid else { throw PhoneError.unsupported(mode: id.mode, what: "Android commands") }
        if let known = serials[id.raw] { return known }
        let listed = try await devices()
        if let known = serials[id.raw] { return known }
        guard listed.contains(where: { $0.id == id }) else { throw PhoneError.unknownDevice(id.description) }
        throw PhoneError.notRunning(id.description)
    }

    private func density(_ serial: String) async throws -> Double {
        if let known = densities[serial] { return known.scale }
        // "Physical density: 420" (and "Override density: 360" after it when set; the last line wins).
        let text = try await shell(serial, ["wm", "density"])
        guard let scale = try PhoneRules.decode(Double?.self, "pixels_per_dp", "pixels_per_dp", ["output": text],
                                                what: "the screen density") else {
            throw PhoneError.unreadable(what: "the screen density")
        }
        densities[serial] = (scale, text)
        return scale
    }

    private func avdName(_ serial: String) async throws -> String {
        let out = try await checked([sdk.adb, "-s", serial, "emu", "avd", "name"], name: "adb emu avd name").stdout
        guard let name = try PhoneRules.decode(String?.self, "name", "avd_name", ["output": PhoneRules.text(out)],
                                               what: "the emulator's AVD name") else {
            throw PhoneError.unreadable(what: "the emulator's AVD name")
        }
        return name
    }

    private func shell(_ serial: String, _ arguments: [String]) async throws -> String {
        let out = try await checked([sdk.adb, "-s", serial, "shell"] + arguments, name: "adb shell").stdout
        return String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func run(_ serial: String, _ arguments: [String], _ name: String, deadline: Duration = .seconds(30)) async throws {
        _ = try await checked([sdk.adb, "-s", serial] + arguments, name: name, deadline: deadline)
    }

    private func checked(_ arguments: [String], name: String, deadline: Duration = .seconds(30)) async throws -> PhoneCommandResult {
        let result = try await runner.run(arguments, stdin: nil, deadline: deadline)
        guard result.status == 0 else { throw PhoneError.commandFailed(command: name, status: result.status, stderr: result.stderr) }
        return result
    }

    /// `Pixel_8_API_35` -> "Pixel 8 API 35".
    static func displayName(_ avd: String) -> String {
        (try? PhoneRules.decode(String.self, "name", "avd_display_name", ["avd": avd], what: "the AVD name")) ?? avd
    }

    /// A USB phone's name: adb's model with spaces, else its serial.
    static func usbModel(_ entry: AndroidDeviceList.Entry) -> String {
        var wire: [String: Any] = ["serial": entry.serial, "state": entry.state]
        if let model = entry.model { wire["model"] = model }
        return (try? PhoneRules.decode(String.self, "model", "usb_model", ["entry": wire], what: "the phone model")) ?? entry.serial
    }

    /// One `adb -s SERIAL` call an input runs.
    private struct AdbCall: Decodable {
        let args: [String]
        let name: String
        let deadlineSeconds: Int64

        enum CodingKeys: String, CodingKey {
            case args, name
            case deadlineSeconds = "deadline_seconds"
        }
    }

    /// `input` as `cmux-phone-core`'s `AndroidInput` reads it.
    static func wire(_ input: PhoneInput) -> [String: Any] {
        switch input {
        case .tap(let point): ["kind": "tap", "x": point.x, "y": point.y]
        case .swipe(let from, let to, let seconds):
            ["kind": "swipe", "from_x": from.x, "from_y": from.y, "to_x": to.x, "to_y": to.y, "seconds": seconds]
        case .text(let text): ["kind": "text", "text": text]
        case .button(let button): ["kind": "button", "button": button.rawValue]
        case .openURL(let url): ["kind": "open_url", "url": url.absoluteString]
        case .pasteboard: ["kind": "pasteboard"]
        case .appearance(let appearance): ["kind": "appearance", "dark": appearance == .dark]
        case .location(let latitude, let longitude): ["kind": "location", "latitude": latitude, "longitude": longitude]
        case .locale(let identifier): ["kind": "locale", "identifier": identifier]
        case .install(let apk): ["kind": "install", "path": apk.path]
        case .launch(let package): ["kind": "launch", "package": package]
        case .softwareKeyboard: ["kind": "software_keyboard"]
        }
    }
}
