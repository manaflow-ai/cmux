import Foundation

struct SimulatorDeviceChromeRaster: Sendable {
    let width: Int
    let height: Int
    let pointWidth: Double
    let pointHeight: Double
    let bytesPerRow: Int
    let bytes: Data
}
