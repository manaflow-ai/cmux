import CoreMedia
@testable import CmuxNextRemoteView
import Testing

@Suite struct RemoteDecoderPrewarmTests {
    @Test func builtInParameterSetsDescribeA128PixelSquare() throws {
        let format = try #require(RemoteVideoFormat.formatDescription(codec: .h264, parameterSets: RemoteDecoderPrewarm.parameterSets))
        let size = CMVideoFormatDescriptionGetDimensions(format)
        #expect(size.width == 128)
        #expect(size.height == 128)
    }
}
