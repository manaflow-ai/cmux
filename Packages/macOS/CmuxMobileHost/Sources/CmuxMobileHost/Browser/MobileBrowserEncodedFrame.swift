public import CMUXMobileCore
public import Foundation

public struct MobileBrowserEncodedFrame {
    public let format: MobileBrowserFrameFormat
    public let data: Data
    public let pixelWidth: Int
    public let pixelHeight: Int

    public init(
        format: MobileBrowserFrameFormat,
        data: Data,
        pixelWidth: Int,
        pixelHeight: Int
    ) {
        self.format = format
        self.data = data
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}
