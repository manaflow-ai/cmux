#if DEBUG
import CmuxNextActions
import CmuxNextSettings
import CmuxNextServer
import Foundation

/// `debug.add_device {computers?, network?, way?}` (captures): Add Device opens on a fixture listing
/// instead of `cmux device list`, so a capture shows the network and ~/.ssh/config rows without the
/// capture machine's own tailnet. `computers`: `[{name, address?, os?, mine?, ssh?}]` (`ssh`: a
/// ~/.ssh/config host); `network`: `"none"` for no Tailscale; `way`: the way to open on, or
/// `"auto"` to open as the card does on its own (default `"network"`). The fixture stays for the
/// rest of the app's run, which a capture starts fresh.
@MainActor
enum DebugAddDevice {
    /// What Add Device shows while set (``AppServices/DebugFixtures/addDevice``): the devices, and the one-line
    /// join's calls (`join`) in place of the CLI and the platform.
    struct Listing {
        var devices: DeviceListing
        var join: MachineJoinService?
    }

    static func show(_ params: [String: JSONValue], services: AppServices) -> JSONValue {
        let rows = params["computers"]?.arrayValue ?? [
            .object(["name": .string("studio"), "os": .string("macOS"), "mine": .bool(true)]),
            .object(["name": .string("build-box"), "os": .string("linux")]),
            .object(["name": .string("devbox"), "ssh": .bool(true)]),
            .object(["name": .string("gpu-west"), "ssh": .bool(true)]),
        ]
        let up = params["network"]?.stringValue != "none"
        let available = rows.compactMap { row -> DeviceListing.Available? in
            guard let name = row["name"]?.stringValue else { return nil }
            let ssh = row["ssh"]?.boolValue ?? false
            return DeviceListing.Available(name: name, address: row["address"]?.stringValue ?? (ssh ? name : "\(name).example.ts.net"),
                                           os: row["os"]?.stringValue ?? "", mine: row["mine"]?.boolValue ?? ssh, fromSSHConfig: ssh)
        }
        let devices = DeviceListing(network: .init(kind: up ? "tailscale" : "none", up: up, this: up ? "this-mac" : nil,
                                               detail: up ? nil : "Tailscale is not installed on this computer."),
                                available: available)
        // Only while labs.machineJoin is on (AddDeviceServices.app reads the switch first); a call
        // with no `join` clears it.
        let join = params["join"]?.stringValue
        services.debugFixtures.addDevice = Listing(devices: devices, join: join.map(Self.joinFixture))
        let way = params["way"]?.stringValue.map { AddDeviceWay(rawValue: $0) } ?? AddDeviceWay.network
        let opening = services.addDevice.open(way: way, over: services.windows.active?.window)
        // The card's Make Line, pressed for the capture; `joined` then reads the list once (as a focus does).
        if let join, join != "idle" {
            let card = services.addDevice
            // task-owner: one fixture mint after the opening's read; ends with it.
            Task { @MainActor in
                await opening.value
                guard let model = card.model.joinLine else { return }
                model.name = "build-box"
                await model.mint()
                await model.refresh()
            }
        }
        return .object(["computers": .number(Double(available.count))])
    }

    /// `join`: `idle` (the Name field), `showing` (the line, 9:41 left), `soon` (40 s left),
    /// `joined` (build-box joined, its checks), `expired`, or `failed`. The token is a fixture.
    static func joinFixture(_ state: String) -> MachineJoinService {
        let left: TimeInterval = switch state {
        case "soon": 40
        case "expired": -1
        default: 581
        }
        let line = JoinLine(line: " curl -fsSL https://cmux.example/v1/machines/join.sh | CMUX_JOIN=cmj_7Q2XK9V4M8RD3TBNW5 sh",
                            joinTokenId: "jt_fixture", expiresAt: Date().addingTimeInterval(left), name: "build-box")
        let joined = JoinedMachine(id: "m_fixture", name: "build-box", state: .online, platform: "linux", hostname: "build-box",
                                   joinTokenId: "jt_fixture", mintedBy: "you@example.com")
        let checks = ["binary", "service", "daemon", "credential", "hub", "heartbeat"].map {
            HostStepResult(step: HostStep(rawValue: $0), state: .ok, detail: "")
        } + [HostStepResult(step: HostStep(rawValue: "consent"), state: .skip, detail: "Screen sharing and control are off")]
        return MachineJoinService(
            mint: { _ in state == "failed" ? .failure(.unavailable) : .success(line) },
            list: { state == "joined" ? [joined] : [] },
            doctor: { _ in checks })
    }
}

extension DebugAddDevice {
    /// The joined machines `debug.joined_machines` lists (online, offline, revoked).
    nonisolated static let joinedRows = [
        JoinedMachine(id: "m_lane", name: "lane-vm-3", state: .online, platform: "linux", hostname: "lane-vm-3",
                      joinTokenId: "jt_1", mintedBy: "you@example.com"),
        JoinedMachine(id: "m_gpu", name: "gpu-west", state: .offline, platform: "linux", joinTokenId: "jt_2", mintedBy: "sam@example.com"),
        JoinedMachine(id: "m_old", name: "old-box", state: .revoked, platform: "macos", joinTokenId: "jt_3"),
    ]

    /// `machine doctor` lines for the fixture's Check (HostStep JSON, then the report).
    static let joinedDoctorLines: [String] = {
        let steps = [("signed-in", "ok", ""), ("platform", "ok", ""), ("listed", "ok", ""),
                     ("heartbeat", "ok", "12 s ago"), ("mesh", "ok", "")]
        let lines = steps.map { #"{"step":"\#($0.0)","state":"\#($0.1)","detail":"\#($0.2)"}"# }
        let report = #"{"report":{"host":"m_lane","name":"lane-vm-3","ok":true,"steps":[\#(lines.joined(separator: ","))]}}"#
        return lines + [report]
    }()

    /// `debug.joined_machines {menu?, check?}` (captures): the Machines section lists the fixture's
    /// joined machines in place of `cmux machine list`, and shows the section. `menu: true` marks the
    /// first row's menu open (its "…" button lit, as while its menu is up; a window capture does not
    /// include the menu's own window). `check: true` opens Check on it with the fixture's doctor
    /// lines. The fixture stays for the rest of the app's run, which a capture starts fresh.
    static func showJoined(_ params: [String: JSONValue], services: AppServices) -> JSONValue {
        // Only while labs.machineJoin is on, as the section itself.
        guard services.settings?.snapshot.machineJoin == true else {
            services.debugFixtures.joinedMachines = nil
            return .object(["machines": .number(0), "reason": .string("labs.machineJoin is off")])
        }
        let rows = joinedRows
        services.debugFixtures.joinedMachines = MachineJoinService(mint: { _ in .failure(.unavailable) }, list: { rows })
        let store = services.joinedMachines
        store.apply(rows)
        _ = services.registry.perform("switchRightSidebarToMachines")
        store.openMenu = params["menu"]?.boolValue == true ? rows[0].id : nil
        if params["check"]?.boolValue == true {
            services.addMachine.checkJoined(id: rows[0].id, name: rows[0].name, over: services.windows.active?.window)
        }
        return .object(["machines": .number(Double(rows.count))])
    }
}
#endif
