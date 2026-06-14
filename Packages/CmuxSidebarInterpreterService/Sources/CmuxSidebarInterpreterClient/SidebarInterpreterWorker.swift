import Foundation

/// The worker side of the out-of-process interpreter: a read-eval-write loop
/// over a length-prefixed stdin/stdout channel.
///
/// Shared by both entry points that run the worker:
/// - the standalone `cmux-sidebar-interpreter` executable, and
/// - the host app re-executing its own binary in worker mode (see
///   ``InterpreterClient/workerModeArgument``), which avoids bundling a
///   separate helper.
///
/// Returns when stdin reaches end-of-stream (the host closed the pipe). The
/// caller should `exit` afterwards; this must run before any AppKit/SwiftUI
/// initialization in the re-exec case.
public func runSidebarInterpreterWorker() {
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
}
