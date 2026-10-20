import CoreImage
@testable import CmuxNextDesign
import Testing

/// The blurred fill behind shrunk art (beside the sidebar, where the art slides off an edge to
/// keep its subject whole) keeps the art's own tone (Lawrence 2026-10-19: "it should just have a
/// border on the sidebar, not a different color"). It used to be dimmed, so the sidebar read as a
/// darker panel with a hard edge where the art began.
@Suite struct BackdropArtFillToneTests {
    @Test(arguments: [0.2, 0.5, 0.8])
    func theFillKeepsTheArtsTone(gray: Double) throws {
        let color = CIColor(red: gray, green: gray, blue: gray)
        var image = CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: 400, height: 400))
        for filter in WindowMaterialView.fillFilters() {
            filter.setValue(image, forKey: kCIInputImageKey)
            image = try #require(filter.outputImage)
        }
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        context.render(image, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 200, y: 200, width: 1, height: 1),
                       format: .RGBA8, colorSpace: nil)
        let expected = gray * 255
        for channel in pixel.prefix(3) {
            #expect(abs(Double(channel) - expected) <= 2, "the fill turns \(expected) into \(channel)")
        }
    }
}
