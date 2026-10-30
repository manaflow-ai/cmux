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
    /// adb serial -> pixels per dp.
    private var densities: [String: Double] = [:]

    /// - Parameters:
    ///   - sdk: the SDK whose tools run.
    ///   - runner: runs commands with the tool's absolute path first (``PhoneProcessRunner`` with no launcher).
    public init(sdk: AndroidSDK, runner: any PhoneCommandRunning = PhoneProcessRunner(launcher: nil)) {
        self.sdk = sdk
        self.runner = runner
    }

    public func devices() async throws -> [PhoneDevice] {
        let avds = try await checked([sdk.emulator, "-list-avds"], name: "emulator -list-avds").stdout
        let names = String(decoding: avds, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
            .filter { !$0.isEmpty && !$0.hasPrefix("INFO") }
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
                let model = entry.model.map { $0.replacingOccurrences(of: "_", with: " ") } ?? entry.serial
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
        let taken = Set(serials.values.compactMap { $0.hasPrefix("emulator-") ? Int($0.dropFirst(9)) : nil })
        guard let port = stride(from: 5554, through: 5682, by: 2).first(where: { !taken.contains($0) }) else {
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
        switch input {
        case .tap(let point):
            let scale = try await density(serial)
            try await run(serial, ["shell", "input", "tap", px(point.x, scale), px(point.y, scale)], "adb input tap")
        case .swipe(let from, let to, let seconds):
            let scale = try await density(serial)
            try await run(serial, ["shell", "input", "swipe", px(from.x, scale), px(from.y, scale), px(to.x, scale), px(to.y, scale),
                                   String(Int((seconds * 1000).rounded()))], "adb input swipe")
        case .text(let text):
            // `input text` reads %s as a space; the device shell parses the one quoted argument.
            try await run(serial, ["shell", "input text " + Self.quoted(text.replacingOccurrences(of: " ", with: "%s"))], "adb input text")
        case .button(let button):
            try await run(serial, ["shell", "input", "keyevent", Self.keycode(button)], "adb input keyevent")
        case .openURL(let url):
            try await run(serial, ["shell", "am start -a android.intent.action.VIEW -d " + Self.quoted(url.absoluteString)], "adb am start")
        case .pasteboard, .softwareKeyboard:
            throw PhoneError.unsupported(mode: id.mode, what: input.kind)
        case .appearance(let appearance):
            try await run(serial, ["shell", "cmd", "uimode", "night", appearance == .dark ? "yes" : "no"], "adb cmd uimode")
        case .location(let latitude, let longitude):
            guard id.mode == .emulator else { throw PhoneError.unsupported(mode: id.mode, what: input.kind) }
            try await run(serial, ["emu", "geo", "fix", String(longitude), String(latitude)], "adb emu geo fix")
        case .locale(let identifier):
            // Emulator images allow adb root; restarting zygote applies the locale to every app.
            guard id.mode == .emulator else { throw PhoneError.unsupported(mode: id.mode, what: input.kind) }
            let tag = identifier.replacingOccurrences(of: "_", with: "-")
            try await run(serial, ["root"], "adb root")
            try await run(serial, ["shell", "setprop persist.sys.locale " + Self.quoted(tag) + " && setprop ctl.restart zygote"],
                          "adb setprop locale")
        case .install(let apk):
            try await run(serial, ["install", "-r", apk.path], "adb install", deadline: .seconds(300))
        case .launch(let package):
            try await run(serial, ["shell", "monkey", "-p", package, "-c", "android.intent.category.LAUNCHER", "1"], "adb monkey")
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
        let text = try await shell(serial, ["wm", "size"])
        let dims = text.split(whereSeparator: \.isNewline).last?.split(separator: ":").last?
            .split(separator: "x").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) } ?? []
        guard dims.count == 2 else { throw PhoneError.unreadable(what: "the screen size") }
        let scale = try await density(serial)
        // wm size is the natural (portrait) size; screencap and taps follow the rotation.
        let rotation = (try? await shell(serial, ["settings", "get", "system", "user_rotation"])).flatMap { Int($0) } ?? 0
        let (w, h) = rotation % 2 == 1 ? (dims[1], dims[0]) : (dims[0], dims[1])
        return PhonePoint(x: w / scale, y: h / scale)
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
        return text.lowercased().hasSuffix("yes") ? .dark : .light
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
        if let known = densities[serial] { return known }
        let text = try await shell(serial, ["wm", "density"])
        // "Physical density: 420" (and "Override density: 360" after it when set; the last line wins).
        guard let dpi = text.split(whereSeparator: \.isNewline).last?.split(separator: ":").last
            .flatMap({ Double($0.trimmingCharacters(in: .whitespaces)) }), dpi > 0 else {
            throw PhoneError.unreadable(what: "the screen density")
        }
        densities[serial] = dpi / 160
        return dpi / 160
    }

    private func avdName(_ serial: String) async throws -> String {
        let out = try await checked([sdk.adb, "-s", serial, "emu", "avd", "name"], name: "adb emu avd name").stdout
        guard let name = String(decoding: out, as: UTF8.self).split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty && $0 != "OK" }) else {
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

    private nonisolated func px(_ points: Double, _ scale: Double) -> String {
        String(Int((points * scale).rounded()))
    }

    /// `Pixel_8_API_35` -> "Pixel 8 API 35".
    static func displayName(_ avd: String) -> String { avd.replacingOccurrences(of: "_", with: " ") }

    /// One single-quoted word for the device's `sh`.
    static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func keycode(_ button: PhoneButton) -> String {
        switch button {
        case .home: "KEYCODE_HOME"
        case .lock: "KEYCODE_POWER"
        case .volumeUp: "KEYCODE_VOLUME_UP"
        case .volumeDown: "KEYCODE_VOLUME_DOWN"
        case .siri: "KEYCODE_ASSIST"
        case .back: "KEYCODE_BACK"
        case .appSwitch: "KEYCODE_APP_SWITCH"
        }
    }
}
