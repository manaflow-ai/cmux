import CmuxSidebarInterpreterClient
import Foundation

// The out-of-process sidebar interpreter worker.
//
// Reads length-prefixed `InterpreterRequest` JSON frames from stdin, runs the
// interpreter, and writes `InterpreterResponse` frames to stdout. Crashing,
// hanging, or exhausting resources here only kills this process; the host
// (which supervises us via `InterpreterClient`) detects the closed pipe and
// recovers. Diagnostics must go to stderr; stdout carries only the protocol.

let channel = LengthPrefixedMessageChannel(readFD: 0, writeFD: 1)
let runner = RenderInterpreterRunner()
let decoder = JSONDecoder()
let encoder = JSONEncoder()

while let data = channel.receiveMessage() {
    guard let request = try? decoder.decode(InterpreterRequest.self, from: data) else {
        continue // skip an undecodable frame rather than tear down the worker
    }
    let response = runner.run(request)
    guard let payload = try? encoder.encode(response) else { continue }
    try? channel.sendMessage(payload)
}
