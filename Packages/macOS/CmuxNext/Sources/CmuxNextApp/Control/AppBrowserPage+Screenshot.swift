import CmuxNextBrowser
import CmuxNextControl
import CmuxNextSettings
import CoreGraphics
import Foundation

/// `browser.page.screenshot`: the page's pixels as a PNG file in the
/// temporary directory (`path`, as the old app wrote one), and inline as
/// base64 when it is small enough for one control-socket answer.
extension AppBrowserPage {
    /// Base64 grows a PNG by a third; the control socket drops an answer
    /// over 8 MiB.
    static let inlinePNGLimit = 4 << 20
    static func screenshot(_ page: any BrowserTab, tabID: String, _ capture: BrowserPageCapture) async throws -> JSONValue {
        let files = BrowserScreenshotFiles(directory: FileManager.default.temporaryDirectory.appendingPathComponent("cmux-browser-screenshots", isDirectory: true))
        let image: CGImage
        do {
            switch capture {
            case .viewport: image = try await page.snapshot()
            case .fullPage: image = try await page.fullPageSnapshot()
            case .clip(let clip):
                guard let cropped = files.crop(try await page.snapshot(), rect: CGRect(x: clip.x, y: clip.y, width: clip.width, height: clip.height),
                                             viewport: CGSize(width: clip.viewportWidth, height: clip.viewportHeight)) else {
                    throw ControlError(code: "unavailable", message: BrowserPageCaptureStrings().clipOutside)
                }
                image = cropped
            }
        } catch let error as ControlError {
            throw error
        } catch {
            throw ControlError(code: "unavailable", message: BrowserPageCaptureStrings().captureFailed(String(describing: error)))
        }
        guard let png = await files.pngData(image) else {
            throw ControlError(code: "app_error", message: BrowserPageCaptureStrings().encodeFailed)
        }
        let path: String
        do {
            path = try await files.save(png, tabID: tabID)
        } catch {
            throw ControlError(code: "app_error", message: BrowserPageCaptureStrings().saveFailed(error.localizedDescription))
        }
        var result: JSONValue = ["path": .string(path), "width": JSONValue(image.width), "height": JSONValue(image.height)]
        if png.count <= inlinePNGLimit, case .object(var members) = result {
            members["png_base64"] = .string(await files.base64(png))
            result = .object(members)
        }
        return result
    }

    /// A script's value as the control reply's JSON, converted off the main actor (an agent's DOM
    /// snapshot or page text is megabytes).
    @concurrent
    static func json(_ value: BrowserJSValue) async -> JSONValue {
        JSONValue(foundation: value.foundationValue) ?? .null
    }

}
