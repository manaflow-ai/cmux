#if DEBUG
import CmuxMobileShellModel
import Foundation

struct MobileIrohReleaseGateTerminalProbe: Sendable {
    private static let maximumRetainedByteCount = 65_536

    let command: Data

    private let markerData: Data
    private var received = Data()

    init(marker: String) {
        markerData = Data(marker.utf8)
        command = Data("printf '\\n%s\\n' '\(marker)'\n".utf8)
    }

    mutating func consume(_ chunk: MobileTerminalOutputChunk) -> Bool {
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
