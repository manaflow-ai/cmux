internal import CMUXMobileCore
internal import Foundation
internal import GhosttyKit

/// One bounded render-grid capture serialized with native surface teardown.
struct TerminalSurfaceRuntimeRenderGridRequest: @unchecked Sendable {
    static let maximumJSONByteCount = 6 * 1_024 * 1_024
    static let maximumSpanCount = 100_000

    let surface: ghostty_surface_t
    let surfaceID: String
    let stateSeq: UInt64
    let full: Bool
    let changedRows: Set<Int>?
    let scrollbackLines: Int
    let scrollForwardLines: Int

    func read() -> (frame: MobileTerminalRenderGridFrame, rows: [String])? {
        let exported = surfaceID.withCString { pointer in
            ghostty_surface_render_grid_json_bounded(
                surface,
                pointer,
                UInt(surfaceID.utf8.count),
                stateSeq,
                UInt(max(0, scrollbackLines)),
                UInt(max(0, scrollForwardLines))
            )
        }
        defer { ghostty_string_free(exported) }
        guard let pointer = exported.ptr,
              let byteCount = Int(exactly: exported.len),
              byteCount > 0,
              byteCount <= Self.maximumJSONByteCount else {
            return nil
        }

        let data = Data(bytes: pointer, count: byteCount)
        guard let fullFrame = try? JSONDecoder().decode(
            MobileTerminalRenderGridFrame.self,
            from: data
        ), fullFrame.totalSpanCount <= Self.maximumSpanCount else {
            return nil
        }
        let frame: MobileTerminalRenderGridFrame
        if full, changedRows == nil {
            frame = fullFrame
        } else {
            let includedRows = changedRows ?? Set(0..<fullFrame.rows)
            guard let filtered = try? fullFrame.filteredRows(includedRows, full: full) else {
                return nil
            }
            frame = filtered
        }
        return (frame, frame.plainRows())
    }
}
