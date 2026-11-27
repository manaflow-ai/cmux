import Foundation
import Testing
@testable import CmuxNextDaemon

/// Throwaway capture of the hand-written encoders' bytes (never merged).
struct GoldenCaptureTests {
    private func show(_ name: String, _ request: some DaemonRequest) throws {
        let bytes = try WireCoding.encodeRequest(request, id: 1)
        print("GOLDEN \(name) \(String(decoding: bytes, as: UTF8.self))")
    }

    @Test func capture() throws {
        try show("process-info", TerminalProcessInfoRequest(surface: SurfaceID(rawValue: 7)))
        let ref = RemoteTerminalRef(sessionID: "ABC-1", terminalID: TerminalID(rawValue: "t1"), sessionName: "mac")
        try show("remote-min", NewRemoteTerminalTabRequest(ref))
        try show("remote-full", NewRemoteTerminalTabRequest(ref, pane: PaneID(rawValue: 3), title: "build", size: CellSize(cols: 120, rows: 40)))
        try show("put-blob", PutBlobRequest(mediaType: "image/png", data: Data([0, 1, 2, 250])))
        try show("personal-set", SetPersonalTerminalRequest(sessionID: "s", terminalKey: "k", theme: "dracula"))
        try show("personal-clear", SetPersonalTerminalRequest(sessionID: "s", terminalKey: "k", theme: nil))
        print("GOLDEN caps \(String(describing: TerminalProcessInfoRequest.requiredCapability)) \(String(describing: NewRemoteTerminalTabRequest.requiredCapability)) \(String(describing: PutBlobRequest.requiredCapability)) \(String(describing: SetPersonalTerminalRequest.requiredCapability))")
    }
}
