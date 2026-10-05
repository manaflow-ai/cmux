public import Foundation

extension CEFTab: BrowserProcessReporting, BrowserURLSaving {
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
    /// Save Link As…: downloads `url` with this tab's session into the chosen file (`CEFDownloads`).
    public func save(_ url: URL, to destination: URL) { _ = browserID.map { runtime.downloads.save(url, to: destination, browser: $0) } }
}
