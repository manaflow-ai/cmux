import AppKit
import CmuxTerminalRenderer
import Darwin
import Foundation

NSApplication.shared.setActivationPolicy(.prohibited)
guard let surfacePortServiceName = ProcessInfo.processInfo.environment[
    "CMUX_RENDERER_SURFACE_PORT_SERVICE"
] else {
    FileHandle.standardError.write(Data("renderer worker missing surface port service\n".utf8))
    Darwin.exit(EXIT_FAILURE)
}
let listener: RendererWorkerStdioListener
do {
    listener = try RendererWorkerStdioListener(
        surfacePortServiceName: surfacePortServiceName
    )
} catch {
    FileHandle.standardError.write(Data("renderer worker port setup failed: \(error)\n".utf8))
    Darwin.exit(EXIT_FAILURE)
}

Task { @MainActor in
    do {
        let runtime = try GhosttyRendererWorkerRuntime(listener: listener)
        await runtime.run()
        // EOF means the owning cmux process closed its pipe or exited. Do not
        // leave a headless renderer helper orphaned behind it.
        Darwin.exit(EXIT_SUCCESS)
    } catch {
        FileHandle.standardError.write(Data("renderer worker failed: \(error)\n".utf8))
        Darwin.exit(EXIT_FAILURE)
    }
}

NSApplication.shared.run()
