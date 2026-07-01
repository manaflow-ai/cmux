import AppKit
import CmuxSidebarInterpreterClient
import Foundation

/// The render-worker process entry point: a faceless AppKit process that
/// interprets AND renders the untrusted sidebar file, sharing the resulting
/// layer tree with the host via a remote CoreAnimation context.
///
/// The host app re-executes its own binary with
/// ``RenderWorkerClient/workerModeArgument``; `CmuxMain` routes here *before*
/// any of the app's own startup. Never returns: exits when the host closes
/// stdin (or dies, which closes it too).
public func runSidebarRenderWorker() -> Never {
    let channel = LengthPrefixedMessageChannel(readFD: 0, writeFD: 1)
    let (messages, continuation) = AsyncStream.makeStream(of: RenderWorkerInbound.self)

    // Reader thread: blocking framed reads off stdin (same justified pattern
    // as the clients' reader threads — the fd is the only wake-up source).
    // Yields preserve arrival order into the stream; the single main-actor
    // consumer below applies them in that order.
    let reader = Thread {
        let decoder = JSONDecoder()
        while let data = channel.receiveMessage() {
            guard let message = try? decoder.decode(RenderWorkerInbound.self, from: data) else {
                continue
            }
            continuation.yield(message)
        }
        continuation.finish()
    }
    reader.stackSize = 1 << 20
    reader.name = "cmux-sidebar-render-worker-reader"
    reader.start()

    // The process entry point runs on the main thread by definition.
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        // Faceless: no Dock icon, no focus stealing, no windows on screen.
        app.setActivationPolicy(.prohibited)

        let coordinator = RenderWorkerCoordinator(channel: channel)
        Task { @MainActor in
            for await message in messages {
                coordinator.handle(message)
            }
            // EOF: the host closed the pipe or died. Nothing left to render.
            exit(0)
        }

        app.run()
    }
    // Backstop satisfying `-> Never`: reached only if something stops the run
    // loop (the EOF path above exits directly).
    exit(0)
}
