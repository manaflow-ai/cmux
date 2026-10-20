import CoreGraphics
import Foundation

@testable import CmuxSimulatorUI

func simulatorFrameSnapshot(
    pixel: UInt32,
    sequence: UInt64,
    width: Int = 2,
    height: Int = 2
) -> SimulatorFrameSnapshot {
    var values = Array(repeating: pixel, count: width * height)
    let pixels = values.withUnsafeMutableBytes { Data($0) }
    return SimulatorFrameSnapshot(
        pixels: pixels,
        width: width,
        height: height,
        bytesPerRow: width * 4,
        sequence: sequence
    )
}

func simulatorFrameImageFirstPixel(_ value: Any?) -> UInt32? {
    guard let value,
          CFGetTypeID(value as CFTypeRef) == CGImage.typeID else { return nil }
    let image = unsafeBitCast(value as AnyObject, to: CGImage.self)
    guard let provider = image.dataProvider,
          let data = provider.data,
          CFDataGetLength(data) >= 4,
          let bytes = CFDataGetBytePtr(data) else { return nil }
    return bytes.withMemoryRebound(to: UInt32.self, capacity: 1) { $0.pointee }
}
