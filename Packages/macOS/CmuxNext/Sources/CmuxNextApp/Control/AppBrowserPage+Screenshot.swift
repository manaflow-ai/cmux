import CmuxNextBrowser
import CmuxNextControl
import CmuxNextSettings
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// `browser.page.screenshot`: the page's pixels as a PNG file in the
/// temporary directory (`path`, as the old app wrote one), and inline as
/// base64 when it is small enough for one control-socket answer.
extension AppBrowserPage {
    /// Base64 grows a PNG by a third; the control socket drops an answer
    /// over 8 MiB.
    static let inlinePNGLimit = 4 << 20
    /// Saved screenshots are pruned on each save: at most this many, none
    /// older than an hour, so agents that never pass `--out` do not fill the disk.
    nonisolated static let keptScreenshots = 32
    nonisolated static let screenshotLifetime: TimeInterval = 3600

    static func screenshot(_ page: any BrowserTab, tabID: String, _ capture: BrowserPageCapture) async throws -> JSONValue {
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
            throw ControlError(code: "unavailable", message: BrowserPageStrings.captureFailed(String(describing: error)))
        }
        guard let png = await pngData(image) else {
            throw ControlError(code: "app_error", message: BrowserPageStrings.encodeFailed)
        }
        let path: String
        do {
            path = try await save(png, tabID: tabID)
        } catch {
            throw ControlError(code: "app_error", message: BrowserPageStrings.saveFailed(error.localizedDescription))
        }
        var result: JSONValue = ["path": .string(path), "width": JSONValue(image.width), "height": JSONValue(image.height)]
        if png.count <= inlinePNGLimit, case .object(var members) = result {
            members["png_base64"] = .string(png.base64EncodedString())
            result = .object(members)
        }
        return result
    }

    /// The part of a viewport snapshot `clip` covers (CSS px scaled to the
    /// snapshot's pixels).
    static func crop(_ image: CGImage, to clip: BrowserPageClip) throws -> CGImage {
        let scaleX = Double(image.width) / clip.viewportWidth
        let scaleY = Double(image.height) / clip.viewportHeight
        guard scaleX.isFinite, scaleY.isFinite, scaleX > 0, scaleY > 0 else {
            throw ControlError(code: "unavailable", message: BrowserPageStrings.clipOutside)
        }
        let rect = CGRect(x: clip.x * scaleX, y: clip.y * scaleY, width: clip.width * scaleX, height: clip.height * scaleY)
            .integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !rect.isEmpty, let cropped = image.cropping(to: rect) else {
            throw ControlError(code: "unavailable", message: BrowserPageStrings.clipOutside)
        }
        return cropped
    }

    /// Encodes off the main actor: a full page can be many megapixels.
    @concurrent
    static func pngData(_ image: CGImage) async -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// Writes off the main actor to `$TMPDIR/cmux-browser-screenshots/`.
    @concurrent
    static func save(_ png: Data, tabID: String) async throws -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-browser-screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let file = directory.appendingPathComponent("\(tabID)-\(stamp)-\(UUID().uuidString.prefix(8)).png")
        try png.write(to: file, options: .atomic)
        prune(directory, keeping: keptScreenshots, newerThan: Date().addingTimeInterval(-screenshotLifetime))
        return file.path
    }

    /// Deletes the PNGs in `directory` past the newest `keeping`, and any
    /// modified before `cutoff`. Best effort: a file another save is
    /// writing or a reader holds open is left for the next prune.
    nonisolated static func prune(_ directory: URL, keeping: Int, newerThan cutoff: Date) {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
                                                           options: [.skipsHiddenFiles]) else { return }
        let dated = files.filter { $0.pathExtension == "png" }.map { file in
            (file, (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }.sorted { $0.1 > $1.1 }
        for (index, (file, modified)) in dated.enumerated() where index >= keeping || modified < cutoff {
            try? manager.removeItem(at: file)
        }
    }
}

/// Keys live in Resources/MiscHandlers.xcstrings.
enum BrowserPageStrings {
    static func captureFailed(_ reason: String) -> String {
        String(format: String(localized: "handlers.browserPage.captureFailed", defaultValue: "The page could not be captured (%@); show the tab and retry",
                              table: "MiscHandlers", bundle: .module), reason)
    }
    static var encodeFailed: String {
        String(localized: "handlers.browserPage.encodeFailed", defaultValue: "The screenshot could not be encoded as PNG", table: "MiscHandlers", bundle: .module)
    }
    static func saveFailed(_ reason: String) -> String {
        String(format: String(localized: "handlers.browserPage.saveFailed", defaultValue: "The screenshot could not be saved: %@",
                              table: "MiscHandlers", bundle: .module), reason)
    }
    static var clipOutside: String {
        String(localized: "handlers.browserPage.clipOutside", defaultValue: "The element is outside the captured viewport", table: "MiscHandlers", bundle: .module)
    }
}
