import UIKit
import XCTest

/// CMUX-49: the Workspaces page's launch states on mock data, one indicator at
/// a time. A first launch says what it loads (and never "Updating…" over the
/// placeholders), an offline one says it waits for a connection, a failed one
/// says why with Retry, and a cached list whose refresh failed keeps its rows.
final class WorkspacesLaunchStatesUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func launch(_ demo: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-no-restore",
                                "-cmux-mobile-demo", demo]
        app.launch()
        return app
    }

    private func text(_ app: XCUIApplication, containing value: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", value)).firstMatch
    }

    @MainActor
    func testFirstLaunchSaysWhatItLoadsWithOneIndicator() {
        let app = launch("retry-first-launch")
        defer { app.terminate() }
        let loading = app.descendants(matching: .any)["workspaces.loading"]
        XCTAssertTrue(loading.waitForExistence(timeout: 30), "first-launch placeholders\n\(app.debugDescription)")
        XCTAssertTrue(text(app, containing: "Loading workspaces").waitForExistence(timeout: 5),
                      "the placeholders say what loads\n\(app.debugDescription)")
        // Past the 1.5 s "Updating…" delay: the title must not stack a second indicator.
        XCTAssertFalse(text(app, containing: "Updating").waitForExistence(timeout: 3), "no stacked Updating…")
        XCTAssertFalse(app.descendants(matching: .any)["workspaces.empty.all"].exists, "no empty claim while loading")
        XCTAssertFalse(text(app, containing: "Connect a Mac").exists, "no connect-a-Mac claim while loading")
        attach(app, "first-launch")
    }

    @MainActor
    func testFirstLaunchOfflineSaysItWaits() {
        let app = launch("retry-first-launch-offline")
        defer { app.terminate() }
        XCTAssertTrue(text(app, containing: "Waiting for a connection").waitForExistence(timeout: 30),
                      "offline first launch\n\(app.debugDescription)")
        attach(app, "first-launch-offline")
    }

    @MainActor
    func testFailedFirstLaunchSaysWhyAndOffersRetry() {
        let app = launch("retry-first-launch-failed")
        defer { app.terminate() }
        XCTAssertTrue(app.descendants(matching: .any)["workspaces.retry"].waitForExistence(timeout: 30),
                      "failed first launch\n\(app.debugDescription)")
        XCTAssertTrue(text(app, containing: "This iPhone is offline").exists, "the reason\n\(app.debugDescription)")
        // Exactly one Retry: the offline pill is status only, the page offers the retry.
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == %@", "Retry")).count, 1,
                       "one Retry on screen\n\(app.debugDescription)")
        attach(app, "first-launch-failed")
    }

    @MainActor
    func testFailedRefreshKeepsTheCachedRows() {
        let app = launch("retry-refresh-failed")
        defer { app.terminate() }
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "workspace.row.")).firstMatch.waitForExistence(timeout: 30),
                      "cached rows stay\n\(app.debugDescription)")
        XCTAssertFalse(app.descendants(matching: .any)["workspaces.retry"].exists, "no error page over the rows")
        // No connection words over kept rows (iOS release bar read-back: "Couldn't refresh · last known").
        XCTAssertFalse(text(app, containing: "last known").waitForExistence(timeout: 3), "no stale-rows text\n\(app.debugDescription)")
        XCTAssertFalse(text(app, containing: "Couldn't refresh").exists, "no refresh-failed text\n\(app.debugDescription)")
        attach(app, "refresh-failed")
    }

    /// The first-load hand-off (#48907, #48947): the team loads, then the Macs' lists load, then an
    /// offline Mac's line comes with the list's own loading rows, then the rows (DemoDriver
    /// `retry-first-launch-handoff`, 2.5 s a phase). From the first placeholder row to the rows,
    /// something is drawn in the rows' band. It reads the screen, not the accessibility tree: a
    /// placeholder waiting out its 250 ms show delay is in the tree at opacity 0 (handoff-red-4
    /// a530d27a passed on the blink), so each sample is a screenshot of the band.
    @MainActor
    func testFirstLoadHandOffKeepsThePlaceholderRowsUntilTheRows() { handOff(dark: false) }

    /// The same in dark appearance: the background and the bars are other grays.
    @MainActor
    func testFirstLoadHandOffKeepsThePlaceholderRowsUntilTheRowsDark() { handOff(dark: true) }

    /// The rows' band in points (iPhone 17 Pro portrait, 402 x 874): below the search field and the
    /// loading caption, above the tab bar; the placeholder rows fill it in every phase.
    static let handOffBand = CGRect(x: 20, y: 190, width: 360, height: 330)
    /// The longest wait between two samples the test can judge: under half the 250 ms show delay.
    /// A longer one makes the run INCONCLUSIVE, never a pass.
    static let maxSampleGap: TimeInterval = 0.12
    /// The band is read at 2 pt a pixel.
    static let bandScale: CGFloat = 0.5

    /// What one sample of the band shows. A pixel is luma 0.299 R + 0.587 G + 0.114 B, compared
    /// with the band's background (its most common luma). A bar pixel is neutral (channels within
    /// 14 of each other) and 4 to 60 luma from the background: a placeholder bar, light or dark.
    /// A bar row is a pixel row at least 15% bar pixels; a bar is 2 or more bar rows in a run (4 pt).
    /// Ink is a pixel more than 60 luma from the background (text, icons). Placeholder rows show
    /// when there are 3 or more bars; rows show when ink is 0.3% of the band or more. A sample with
    /// neither shows nothing in the band: the blink.
    struct BandRead { var bars: Int; var ink: Double; var blank: Bool { bars < 3 && ink < 0.003 } }

    static func read(_ px: [UInt8], width: Int, height: Int) -> BandRead {
        var hist = [Int](repeating: 0, count: 256)
        var luma = [Int](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            let r = Int(px[i * 4]), g = Int(px[i * 4 + 1]), b = Int(px[i * 4 + 2])
            let l = (r * 299 + g * 587 + b * 114) / 1000
            luma[i] = l
            hist[l] += 1
        }
        let background = hist.indices.max { hist[$0] < hist[$1] } ?? 0
        var ink = 0, bars = 0, run = 0
        for y in 0..<height {
            var barPixels = 0
            for x in 0..<width {
                let i = y * width + x
                let d = abs(luma[i] - background)
                if d > 60 { ink += 1; continue }
                let r = Int(px[i * 4]), g = Int(px[i * 4 + 1]), b = Int(px[i * 4 + 2])
                if d >= 4, max(r, g, b) - min(r, g, b) <= 14 { barPixels += 1 }
            }
            if barPixels * 100 >= width * 15 {
                run += 1
            } else {
                if run >= 2 { bars += 1 }
                run = 0
            }
        }
        if run >= 2 { bars += 1 }
        return BandRead(bars: bars, ink: Double(ink) / Double(width * height))
    }

    /// The band of a screenshot, downscaled to `bandScale` pixels a point, as RGBA bytes.
    @MainActor
    static func band(_ shot: XCUIScreenshot) -> (px: [UInt8], width: Int, height: Int)? {
        let image = shot.image
        guard let cg = image.cgImage, image.size.width > 0 else { return nil }
        let k = CGFloat(cg.width) / image.size.width
        let rect = CGRect(x: handOffBand.minX * k, y: handOffBand.minY * k, width: handOffBand.width * k, height: handOffBand.height * k)
        guard let crop = cg.cropping(to: rect) else { return nil }
        let width = Int(handOffBand.width * bandScale), height = Int(handOffBand.height * bandScale)
        var px = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = px.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? (px, width, height) : nil
    }

    @MainActor
    private func handOff(dark: Bool) {
        let name = dark ? "dark" : "light"
        if #available(iOS 17.0, *) { XCUIDevice.shared.appearance = dark ? .dark : .light }
        defer { if #available(iOS 17.0, *) { XCUIDevice.shared.appearance = .light } }
        let app = launch("retry-first-launch-handoff")
        defer { app.terminate() }
        let loading = app.descendants(matching: .any)["workspaces.loading"]
        XCTAssertTrue(loading.waitForExistence(timeout: 30), "first-load placeholders\n\(app.debugDescription)")
        // The page's placeholder rows wait out their own show delay first: start once they are drawn.
        let ready = Date()
        var first: BandRead?
        while Date().timeIntervalSince(ready) < 10 {
            if let b = Self.band(XCUIScreen.main.screenshot()) {
                let r = Self.read(b.px, width: b.width, height: b.height)
                if !r.blank { first = r; break }
            }
        }
        guard first != nil else {
            XCTFail("the first-load placeholder rows were never drawn in the band (\(name))")
            return
        }
        attach(app, "handoff-\(name)-first-load")
        // The window: the three phase changes and the rows (7.5 s after the first phase), screenshots
        // only, no accessibility query in between (each costs more than a gap allows).
        var shots: [(t: TimeInterval, px: [UInt8], width: Int, height: Int)] = []
        let start = Date()
        while Date().timeIntervalSince(start) < 9 {
            let t = Date().timeIntervalSince(start)
            if let b = Self.band(XCUIScreen.main.screenshot()) { shots.append((t, b.px, b.width, b.height)) }
        }
        attach(app, "handoff-\(name)-rows")
        var timeline: [String] = []
        var gaps: [TimeInterval] = []
        var blanks: [Int] = []
        for (index, shot) in shots.enumerated() {
            let gap = index == 0 ? 0 : shot.t - shots[index - 1].t
            if index > 0 { gaps.append(gap) }
            let r = Self.read(shot.px, width: shot.width, height: shot.height)
            if r.blank { blanks.append(index) }
            timeline.append(String(format: "%.3f gap=%.0fms bars=%d ink=%.4f%@", shot.t, gap * 1000, r.bars, r.ink, r.blank ? " BLANK" : ""))
        }
        let maxGap = gaps.max() ?? .infinity
        let note = XCTAttachment(string: "appearance \(name), band \(Self.handOffBand) pt, \(shots.count) samples, max gap \(Int(maxGap * 1000)) ms\n"
            + timeline.joined(separator: "\n"))
        note.name = "handoff-\(name)-timeline"
        note.lifetime = .keepAlways
        add(note)
        if let index = blanks.first, let image = Self.image(shots[index].px, width: shots[index].width, height: shots[index].height) {
            let shot = XCTAttachment(image: image)
            shot.name = "handoff-\(name)-first-blank-band"
            shot.lifetime = .keepAlways
            add(shot)
        }
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "workspace.row."))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10), "the rows arrived (\(name))")
        XCTAssertGreaterThan(shots.count, 30, "too few samples to judge (\(name))")
        guard maxGap <= Self.maxSampleGap else {
            XCTFail("INCONCLUSIVE (\(name)): a gap of \(Int(maxGap * 1000)) ms between samples, over \(Int(Self.maxSampleGap * 1000)) ms; gaps: \(gaps.map { Int($0 * 1000) })")
            return
        }
        XCTAssertTrue(blanks.isEmpty, "the placeholder rows blinked out (\(name)): \(blanks.count) blank samples:\n"
            + blanks.map { timeline[$0] }.joined(separator: "\n"))
    }

    /// A band's bytes as an image, to attach.
    static func image(_ px: [UInt8], width: Int, height: Int) -> UIImage? {
        var bytes = px
        return bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let cg = context.makeImage() else { return nil }
            return UIImage(cgImage: cg)
        }
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
