public import Foundation

extension CEFTab: BrowserProcessReporting {
    /// Renderer client ids hosting this tab's frames (main frame, out-of-process iframes; one per site).
    public var contentProcesses: BrowserContentProcesses {
        let ids = rendererClientIDs
        return ids.isEmpty ? .none : .chromiumRendererClients(ids)
    }

    /// The renderer client ids of ``contentProcesses``; empty before the browser exists or
    /// without Chromium.
    public var rendererClientIDs: [Int32] {
        guard let browserID, let shim = runtime.shim else { return [] }
        var ids = [Int32](repeating: 0, count: 32)
        let count = ids.withUnsafeMutableBufferPointer { buffer in
            shim.rendererClientIDs(browserID, buffer.baseAddress, Int32(buffer.count))
        }
        return count > 0 ? Array(ids.prefix(Int(count))) : []
    }
}
