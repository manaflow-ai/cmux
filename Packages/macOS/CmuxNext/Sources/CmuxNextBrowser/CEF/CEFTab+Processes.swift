public import Foundation

extension CEFTab: BrowserProcessReporting {
    /// Renderer client ids hosting this tab's frames (main frame, out-of-process iframes; one per site).
    /// In host mode they come from the host's RENDERER_CLIENTS frames (its mirror), never a call across the wire.
    public var contentProcesses: BrowserContentProcesses {
        guard let browserID else { return .none }
        let ids = runtime.helperWatch?.hostMirror.map { $0.rendererClients(browser: browserID) }
            ?? runtime.shim.map { $0.rendererClients(browser: browserID) } ?? []
        return ids.isEmpty ? .none : .chromiumRendererClients(ids)
    }
}

extension CEFShimLibrary {
    /// `cmux_shim_renderer_client_ids` (in process): the distinct ids, at most 32.
    func rendererClients(browser: Int32) -> [Int32] {
        var ids = [Int32](repeating: 0, count: 32)
        let count = ids.withUnsafeMutableBufferPointer { rendererClientIDs(browser, $0.baseAddress, Int32($0.count)) }
        return Array(ids.prefix(Int(max(count, 0))))
    }
}
