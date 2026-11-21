#if DEBUG
import Foundation

// Captures' fixtures of the one-line join and the joined machines (`debug.add_device {join}`,
// `debug.joined_machines`): no platform, account or network. Names and the token are made up.

extension MachineJoinService {
    /// `join`: `idle` (the Name field), `showing` (the line, 9:41 left), `soon` (40 s left),
    /// `joined` (build-box joined, its checks), `expired`, or `failed`. The token is a fixture.
    public static func fixture(_ state: String) -> MachineJoinService {
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

extension JoinedMachine {
    /// The joined machines `debug.joined_machines` lists (online, offline, revoked).
    public static let fixtures = [
        JoinedMachine(id: "m_lane", name: "lane-vm-3", state: .online, platform: "linux", hostname: "lane-vm-3",
                      joinTokenId: "jt_1", mintedBy: "you@example.com"),
        JoinedMachine(id: "m_gpu", name: "gpu-west", state: .offline, platform: "linux", joinTokenId: "jt_2", mintedBy: "sam@example.com"),
        JoinedMachine(id: "m_old", name: "old-box", state: .revoked, platform: "macos", joinTokenId: "jt_3"),
    ]

    /// `machine doctor` lines for the fixture's Check (HostStep JSON, then the report).
    public static let fixtureDoctorLines: [String] = {
        let steps = [("signed-in", "ok", ""), ("platform", "ok", ""), ("listed", "ok", ""),
                     ("heartbeat", "ok", "12 s ago"), ("mesh", "ok", "")]
        let lines = steps.map { #"{"step":"\#($0.0)","state":"\#($0.1)","detail":"\#($0.2)"}"# }
        let report = #"{"report":{"host":"m_lane","name":"lane-vm-3","ok":true,"steps":[\#(lines.joined(separator: ","))]}}"#
        return lines + [report]
    }()
}
#endif
