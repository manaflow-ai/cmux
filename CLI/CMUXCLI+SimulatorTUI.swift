import Foundation
import Darwin
#if DEBUG
import CMUXDebugLog
#endif

#if DEBUG
extension CMUXCLI {
    /// Interactive list of simulators. Default action when the user runs
    /// `cmux sim` with no subcommand.
    ///
    /// Keys:
    ///   ↑/↓ or j/k    move selection
    ///   Enter         open the device in a bonsplit pane
    ///   b             boot the selected device
    ///   s             shutdown the selected device
    ///   r             refresh now
    ///   q or Ctrl-C   quit
    func runSimulatorTUI(client: SocketClient, idFormat: CLIIDFormat, jsonOutput: Bool) throws {
        // Non-TTY (piped or scripted): fall back to plain list and exit.
        if jsonOutput || isatty(STDIN_FILENO) == 0 || isatty(STDOUT_FILENO) == 0 {
            try runSimulatorList(client: client, jsonOutput: jsonOutput)
            return
        }

        let raw = SimulatorTUIRawMode()
        defer { raw?.restore() }

        let renderer = SimulatorTUIRenderer()
        var devices: [SimulatorTUIDevice] = []
        var selection = 0
        var statusLine = ""
        let pending: SimulatorTUIPendingAction? = nil

        func reload() {
            do {
#if DEBUG
                CMUXDebugLog.logDebugEvent("sim.tui.list.request")
#endif
                let payload = try client.sendV2(method: "simulator.list", params: [:])
                let raw = (payload["devices"] as? [[String: Any]]) ?? []
                devices = raw.compactMap(SimulatorTUIDevice.init(payload:))
                    .sorted {
                        if $0.runtime != $1.runtime { return $0.runtime < $1.runtime }
                        return $0.name < $1.name
                    }
                if devices.isEmpty {
                    selection = 0
                } else {
                    selection = max(0, min(selection, devices.count - 1))
                }
#if DEBUG
                CMUXDebugLog.logDebugEvent("sim.tui.list.success count=\(devices.count)")
#endif
            } catch {
#if DEBUG
                CMUXDebugLog.logDebugEvent("sim.tui.list.error error=\(String(describing: error))")
#endif
                statusLine = "list failed: \(String(describing: error))"
            }
        }

        reload()
        renderer.draw(devices: devices, selection: selection, status: statusLine, pending: pending)

        // Single-threaded loop. poll() blocks up to 200ms for keyboard
        // input, then we re-render. Anything ESC-prefixed is read in
        // burst with a 50ms continuation poll so we capture the full
        // CSI sequence in one place — no second reader thread to race.
        var nextRefresh = Date().addingTimeInterval(2.0)

        loop: while true {
            let waitMs: Int32 = 200
            let key = readKey(timeoutMs: waitMs)

            if let key {
                if key == .ctrlC || key == .char(UInt8(ascii: "q")) {
                    break loop
                }
                let action: SimulatorTUIAction
                switch key {
                case .up:    action = .moveUp
                case .down:  action = .moveDown
                case .char(let c):
                    switch c {
                    case UInt8(ascii: "k"): action = .moveUp
                    case UInt8(ascii: "j"): action = .moveDown
                    case UInt8(ascii: "r"): action = .refresh
                    case UInt8(ascii: "b"): action = .bootSelection
                    case UInt8(ascii: "s"): action = .shutdownSelection
                    case UInt8(ascii: "\r"), UInt8(ascii: "\n"), UInt8(ascii: " "):
                        action = .openSelection
                    default: action = .none
                    }
                case .ctrlC:
                    break loop
                }

                switch action {
                case .none:
                    break
                case .moveUp:
                    if !devices.isEmpty { selection = (selection - 1 + devices.count) % devices.count }
                case .moveDown:
                    if !devices.isEmpty { selection = (selection + 1) % devices.count }
                case .refresh:
                    reload()
                    statusLine = "refreshed (\(devices.count) device\(devices.count == 1 ? "" : "s"))"
                case .openSelection:
                    if let device = devices[safe: selection] {
                        do {
#if DEBUG
                            CMUXDebugLog.logDebugEvent("sim.tui.open.request udid=\(device.udid.prefix(8))")
#endif
                            let payload = try client.sendV2(method: "simulator.open", params: [
                                "udid": device.udid,
                                "direction": "right",
                            ])
                            let surfaceText = formatHandle(payload, kind: "surface", idFormat: idFormat) ?? "?"
                            statusLine = "opened \(device.name) (surface=\(surfaceText))"
#if DEBUG
                            CMUXDebugLog.logDebugEvent("sim.tui.open.success udid=\(device.udid.prefix(8))")
#endif
                        } catch {
#if DEBUG
                            CMUXDebugLog.logDebugEvent("sim.tui.open.error udid=\(device.udid.prefix(8)) error=\(String(describing: error))")
#endif
                            statusLine = "open failed: \(String(describing: error))"
                        }
                    }
                case .bootSelection:
                    if let device = devices[safe: selection] {
                        statusLine = "booting \(device.name)…"
                        renderer.draw(devices: devices, selection: selection, status: statusLine, pending: pending)
                        do {
#if DEBUG
                            CMUXDebugLog.logDebugEvent("sim.tui.boot.request udid=\(device.udid.prefix(8))")
#endif
                            _ = try client.sendV2(method: "simulator.boot", params: ["udid": device.udid])
                            statusLine = "boot requested for \(device.name)"
#if DEBUG
                            CMUXDebugLog.logDebugEvent("sim.tui.boot.success udid=\(device.udid.prefix(8))")
#endif
                        } catch {
#if DEBUG
                            CMUXDebugLog.logDebugEvent("sim.tui.boot.error udid=\(device.udid.prefix(8)) error=\(String(describing: error))")
#endif
                            statusLine = "boot failed: \(String(describing: error))"
                        }
                        reload()
                    }
                case .shutdownSelection:
                    if let device = devices[safe: selection] {
                        statusLine = "shutting down \(device.name)…"
                        renderer.draw(devices: devices, selection: selection, status: statusLine, pending: pending)
                        do {
#if DEBUG
                            CMUXDebugLog.logDebugEvent("sim.tui.shutdown.request udid=\(device.udid.prefix(8))")
#endif
                            _ = try client.sendV2(method: "simulator.shutdown", params: ["udid": device.udid])
                            statusLine = "shutdown requested for \(device.name)"
#if DEBUG
                            CMUXDebugLog.logDebugEvent("sim.tui.shutdown.success udid=\(device.udid.prefix(8))")
#endif
                        } catch {
#if DEBUG
                            CMUXDebugLog.logDebugEvent("sim.tui.shutdown.error udid=\(device.udid.prefix(8)) error=\(String(describing: error))")
#endif
                            statusLine = "shutdown failed: \(String(describing: error))"
                        }
                        reload()
                    }
                }
            }

            if Date() >= nextRefresh {
                reload()
                nextRefresh = Date().addingTimeInterval(2.0)
            }

            renderer.draw(devices: devices, selection: selection, status: statusLine, pending: pending)
        }

        renderer.teardown()
    }

    private enum SimulatorTUIAction {
        case none
        case moveUp, moveDown
        case refresh
        case openSelection
        case bootSelection
        case shutdownSelection
    }

    private enum SimulatorTUIKey: Equatable {
        case up
        case down
        case ctrlC
        case char(UInt8)
    }

    /// Wait up to `timeoutMs` for one keystroke. Decodes CSI arrow keys
    /// by reading any ESC continuation bytes inline, so there's a single
    /// reader and the arrow-key follow-up bytes can never race a
    /// background thread.
    private func readKey(timeoutMs: Int32) -> SimulatorTUIKey? {
        var pfd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        let n = poll(&pfd, 1, timeoutMs)
        guard n > 0, (Int32(pfd.revents) & POLLIN) != 0 else { return nil }

        var byte: UInt8 = 0
        let r = read(STDIN_FILENO, &byte, 1)
        guard r == 1 else { return nil }

        // Ctrl-C
        if byte == 0x03 { return .ctrlC }

        // ESC: try to grab a CSI sequence. Wait briefly for the next byte
        // — if the user pressed plain Esc, it'll time out and we return nil
        // rather than consuming the next unrelated keystroke.
        if byte == 0x1B {
            return readCSITail()
        }

        return .char(byte)
    }

    private func readCSITail() -> SimulatorTUIKey? {
        // ESC alone times out -> ignore. CSI is ESC [ X.
        var pfd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        guard poll(&pfd, 1, 50) > 0 else { return nil }
        var b1: UInt8 = 0
        guard read(STDIN_FILENO, &b1, 1) == 1, b1 == 0x5B else { return nil }
        guard poll(&pfd, 1, 50) > 0 else { return nil }
        var b2: UInt8 = 0
        guard read(STDIN_FILENO, &b2, 1) == 1 else { return nil }
        switch b2 {
        case 0x41: return .up      // ESC [ A
        case 0x42: return .down    // ESC [ B
        default:   return nil
        }
    }
}

// MARK: - models

private struct SimulatorTUIDevice {
    let udid: String
    let name: String
    let runtime: String
    let state: String
    let isBooted: Bool

    init?(payload: [String: Any]) {
        guard let udid = payload["udid"] as? String,
              let name = payload["name"] as? String else { return nil }
        self.udid = udid
        self.name = name
        self.runtime = (payload["runtime"] as? String) ?? ""
        self.state = (payload["state"] as? String) ?? "?"
        self.isBooted = (payload["is_booted"] as? Bool) ?? (state == "booted")
    }
}

private struct SimulatorTUIPendingAction {
    let kind: String
    let udid: String
}

// MARK: - renderer

private final class SimulatorTUIRenderer {
    private var didEnterAlt = false

    func draw(devices: [SimulatorTUIDevice], selection: Int, status: String, pending: SimulatorTUIPendingAction?) {
        if !didEnterAlt {
            print("\u{1B}[?1049h\u{1B}[?25l", terminator: "")  // alt screen + hide cursor
            didEnterAlt = true
        }
        // Clear screen + home
        var out = "\u{1B}[H\u{1B}[2J"

        let title = "cmux simulators"
        out += "\u{1B}[1;36m\(title)\u{1B}[0m  "
        out += "\u{1B}[2m↑/↓ move  ⏎ open in pane  b boot  s shutdown  r refresh  q quit\u{1B}[0m\r\n"
        out += "\u{1B}[2m\(String(repeating: "─", count: max(0, min(80, terminalWidth()))))\u{1B}[0m\r\n"

        if devices.isEmpty {
            out += "\u{1B}[2m  (no simulators found)\u{1B}[0m\r\n"
        } else {
            var lastRuntime: String?
            for (i, device) in devices.enumerated() {
                if device.runtime != lastRuntime {
                    out += "\r\n\u{1B}[1m\(device.runtime.isEmpty ? "Other" : device.runtime)\u{1B}[0m\r\n"
                    lastRuntime = device.runtime
                }
                let isSel = (i == selection)
                let dot = device.isBooted ? "\u{1B}[32m●\u{1B}[0m" : "\u{1B}[2m○\u{1B}[0m"
                let statePill: String
                switch device.state {
                case "booted":      statePill = "\u{1B}[32mbooted\u{1B}[0m"
                case "booting":     statePill = "\u{1B}[33mbooting\u{1B}[0m"
                case "shuttingDown":statePill = "\u{1B}[33mshutting down\u{1B}[0m"
                default:            statePill = "\u{1B}[2m\(device.state)\u{1B}[0m"
                }
                let prefix = isSel ? "\u{1B}[7m▶ " : "  "
                let suffix = isSel ? " \u{1B}[0m" : ""
                let udidShort = String(device.udid.prefix(8))
                out += "\(prefix)\(dot) \(device.name.padding(toLength: 28, withPad: " ", startingAt: 0))  \(udidShort)  \(statePill)\(suffix)\r\n"
            }
        }

        out += "\r\n"
        if !status.isEmpty {
            out += "\u{1B}[2m\(status)\u{1B}[0m\r\n"
        }
        if let pending {
            out += "\u{1B}[33mpending: \(pending.kind) \(pending.udid)\u{1B}[0m\r\n"
        }

        FileHandle.standardOutput.write(Data(out.utf8))
    }

    func teardown() {
        if didEnterAlt {
            print("\u{1B}[?25h\u{1B}[?1049l", terminator: "")  // show cursor + leave alt screen
            didEnterAlt = false
        }
    }

    deinit {
        teardown()
    }

    private func terminalWidth() -> Int {
        var w = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &w) == 0 {
            return Int(w.ws_col)
        }
        return 80
    }
}

// MARK: - raw mode (TUI-local copy so we don't depend on cmux.swift internals)

private final class SimulatorTUIRawMode {
    private var original = termios()
    private var restored = false

    init?() {
        guard tcgetattr(STDIN_FILENO, &original) == 0 else { return nil }
        var raw = original
        cfmakeraw(&raw)
        // Keep VMIN=1/VTIME=0 default semantics so reads are byte-by-byte blocking.
        guard tcsetattr(STDIN_FILENO, TCSANOW, &raw) == 0 else { return nil }
    }

    func restore() {
        guard !restored else { return }
        tcsetattr(STDIN_FILENO, TCSANOW, &original)
        restored = true
    }

    deinit { restore() }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
#endif
