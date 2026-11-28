#if DEBUG
import CmuxMobileShellModel
import Foundation

struct MobileIrohReleaseGateTerminalProbe: Sendable {
    private static let maximumRetainedByteCount = 65_536

    let command: Data

    private let marker: String
    private let markerData: Data
    private var received = Data()

    init(marker: String) {
        self.marker = marker
        markerData = Data(marker.utf8)
        let encodedMarker = marker.utf8
            .map { String(format: "\\%03o", $0) }
            .joined()
        command = Data("printf '\\n\(encodedMarker)\\n'\n".utf8)
    }

    mutating func consume(_ chunk: MobileTerminalOutputChunk) -> Bool {
        if let frame = chunk.sourceRenderGridFrame,
           frame.plainRows().joined().contains(marker) {
            return true
        }
        received.append(chunk.data)
        if received.range(of: markerData) != nil {
            return true
        }
        if received.count > Self.maximumRetainedByteCount {
            received.removeFirst(received.count - Self.maximumRetainedByteCount)
        }
        return false
    }
}
#endif
