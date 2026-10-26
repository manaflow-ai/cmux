public import Foundation

extension CEFTab: BrowserProcessReporting {
    /// Renderer client ids hosting this tab's frames (main frame, out-of-process iframes; one per site).
    public var contentProcesses: BrowserContentProcesses {
        guard let browserID, let shim = runtime.shim else { return .none }
        var ids = [Int32](repeating: 0, count: 32)
        let count = ids.withUnsafeMutableBufferPointer { buffer in
            shim.rendererClientIDs(browserID, buffer.baseAddress, Int32(buffer.count))
        }
        guard count > 0 else { return .none }
        return .chromiumRendererClients(Array(ids.prefix(Int(count))))
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    /// The renderer client ids of ``contentProcesses``; empty before the browser exists or
    /// without Chromium (`debug.webui`).
    public var rendererClientIDs: [Int32] {
        if case .chromiumRendererClients(let ids) = contentProcesses { ids } else { [] }
    }
    #endif
}
