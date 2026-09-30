import Foundation

extension CEFTab: BrowserProcessReporting {
    /// The renderer client ids that host this tab's frames (the main frame
    /// and out-of-process iframes). Chromium assigns renderers per site, so
    /// two tabs of one site can share one.
    public var contentProcesses: BrowserContentProcesses {
        guard let browserID, let shim = runtime.shim else { return .none }
        var ids = [Int32](repeating: 0, count: 32)
        let count = ids.withUnsafeMutableBufferPointer { buffer in
            shim.rendererClientIDs(browserID, buffer.baseAddress, Int32(buffer.count))
        }
        guard count > 0 else { return .none }
        return .chromiumRendererClients(Array(ids.prefix(Int(count))))
    }
}
