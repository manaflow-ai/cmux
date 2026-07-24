import CmuxSidebarInterpreterClient
import CmuxSwiftRender
import Darwin
import Foundation

// Test fixture for RenderWorkerClient supervision tests: speaks the render-
// worker wire protocol without any AppKit/CoreAnimation, so the client's
// spawn/replay/ack/crash behavior is testable headless via `swift test`.
//
// Behavior:
// - announces a fake context id derived from its pid on startup, so tests can
//   tell worker generations apart;
// - acks every scene, unless the scene's file path matches the hang token
//   (then it never acks, exercising the ack watchdog) or the crash token
//   (then it dies hard, exercising respawn + replay);
// - replies to any pointer event with a canned action, exercising the
//   worker → host action path.

let environment = ProcessInfo.processInfo.environment
let crashToken = environment["CMUX_RENDER_FIXTURE_CRASH_TOKEN"]
let hangToken = environment["CMUX_RENDER_FIXTURE_HANG_TOKEN"]
let stopReading: Bool = {
    guard let path = environment["CMUX_RENDER_FIXTURE_STOP_READING_ONCE_PATH"],
          !path.isEmpty else {
        return false
    }
    let descriptor = Darwin.open(path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
    guard descriptor >= 0 else { return false }
    Darwin.close(descriptor)
    return true
}()

guard let channel = try? LengthPrefixedMessageChannel(readFD: 0, writeFD: 1) else {
    exit(1)
}
let decoder = JSONDecoder()
let encoder = JSONEncoder()

func send(_ message: RenderWorkerOutbound) {
    guard let payload = try? encoder.encode(message) else { return }
    try? channel.sendMessage(payload)
}

send(.context(UInt32(truncatingIfNeeded: ProcessInfo.processInfo.processIdentifier)))

if stopReading {
    while true {
        _ = pause()
    }
}

while let data = channel.receiveMessage() {
    guard let message = try? decoder.decode(RenderWorkerInbound.self, from: data) else {
        continue
    }
    switch message {
    case let .scene(scene):
        if let crashToken, !crashToken.isEmpty, scene.filePath == crashToken {
            fatalError("render fixture crash sentinel")
        }
        if let hangToken, !hangToken.isEmpty, scene.filePath == hangToken {
            continue // swallow the scene: never ack, simulating a hung renderer
        }
        send(.ack(scene.seq))
    case .resize:
        continue
    case .pointer:
        send(.action(ButtonAction(commands: [])))
    case .reloadSidebars:
        continue
    }
}
