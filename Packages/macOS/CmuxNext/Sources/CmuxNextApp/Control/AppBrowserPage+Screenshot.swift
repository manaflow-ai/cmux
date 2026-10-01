import CmuxNextBrowser
import CmuxNextControl
import CmuxNextSettings
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// `browser.page.screenshot`: the page's pixels as a base64 PNG.
extension AppBrowserPage {
    static func screenshot(_ page: any BrowserTab, _ capture: BrowserPageCapture) async throws -> JSONValue {
        let image: CGImage
        do {
            switch capture {
            case .viewport: image = try await page.snapshot()
            case .fullPage: image = try await page.fullPageSnapshot()
            case .clip(let clip): image = try crop(try await page.snapshot(), to: clip)
            }
        } catch let error as ControlError {
            throw error
        } catch {
            throw ControlError(code: "unavailable", message: "The page could not be captured (\(error)); show the tab and retry")
        }
        guard let png = await pngBase64(image) else {
            throw ControlError(code: "app_error", message: "The screenshot could not be encoded as PNG")
        }
        return ["png_base64": .string(png), "width": JSONValue(image.width), "height": JSONValue(image.height)]
    }

    /// The part of a viewport snapshot `clip` covers (CSS px scaled to the
    /// snapshot's pixels).
    static func crop(_ image: CGImage, to clip: BrowserPageClip) throws -> CGImage {
        let scaleX = Double(image.width) / clip.viewportWidth
        let scaleY = Double(image.height) / clip.viewportHeight
        let rect = CGRect(x: clip.x * scaleX, y: clip.y * scaleY, width: clip.width * scaleX, height: clip.height * scaleY)
            .integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard scaleX.isFinite, scaleY.isFinite, !rect.isEmpty, let cropped = image.cropping(to: rect) else {
            throw ControlError(code: "unavailable", message: "The element is outside the captured viewport")
        }
        return cropped
    }

    /// Encodes off the main actor: a full page can be many megapixels.
    @concurrent
    static func pngBase64(_ image: CGImage) async -> String? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? (data as Data).base64EncodedString() : nil
    }
}
