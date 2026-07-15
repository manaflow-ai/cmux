import Foundation
import IOSurface

@testable import CmuxSimulatorUI

final class EmptySimulatorFrameSurfaceSource: SimulatorFrameSurfaceReading, Sendable {
    private let snapshot: SimulatorFrameSnapshot?

    init(latestFrame: (surface: IOSurface, sequence: UInt64)? = nil) {
        guard let latestFrame else {
            snapshot = nil
            return
        }
        let surface = latestFrame.surface
        let width = IOSurfaceGetWidth(surface)
        let height = IOSurfaceGetHeight(surface)
        let sourceBytesPerRow = IOSurfaceGetBytesPerRow(surface)
        let bytesPerRow = width * 4
        var pixels = Data(count: bytesPerRow * height)
        IOSurfaceLock(surface, [.readOnly], nil)
        pixels.withUnsafeMutableBytes { destination in
            let source = IOSurfaceGetBaseAddress(surface)
            for row in 0..<height {
                memcpy(
                    destination.baseAddress?.advanced(by: row * bytesPerRow),
                    source.advanced(by: row * sourceBytesPerRow),
                    bytesPerRow
                )
            }
        }
        IOSurfaceUnlock(surface, [.readOnly], nil)
        snapshot = SimulatorFrameSnapshot(
            pixels: pixels,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            sequence: latestFrame.sequence
        )
    }

    init(snapshot: SimulatorFrameSnapshot?) {
        self.snapshot = snapshot
    }

    func hasPublishedFrame(after sequence: UInt64?) -> Bool {
        guard let snapshot else { return false }
        return sequence.map { snapshot.sequence > $0 } ?? true
    }

    func copyLatestFrame(after sequence: UInt64?) async -> SimulatorFrameSnapshot? {
        guard let snapshot,
              sequence.map({ snapshot.sequence > $0 }) ?? true else { return nil }
        return snapshot
    }
}
