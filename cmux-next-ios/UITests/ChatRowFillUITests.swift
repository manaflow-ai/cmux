import XCTest

/// Leo, 2026-11-22: "ALSO I REMEMBER CLICKING THE FUCKING THOUGHT TOOL CALL IN IOS AND IT HAD THAT
/// STUPID FUCKING SQUARE PLACEHOLDER BACKING / THAT AINT RIGHT / LIKEWISE / THE YELLOW AND RED
/// PLACEHOLDERS FOR SHIT / GO FUCKING AUDIT THAT SHIT AND PREVENT THAT SHIT FROM FUCKING HAPPENING"
///
/// Opens the shipping app's offline DEBUG agent chat (`-cmux-mobile-demo disclosure-chat`) under
/// Mac themes (`-cmux-mobile-mac-appearance`, ChatLookFixture.swift) and opens and closes every
/// disclosure row on screen (thought, tool call, tool group, subagents, "Worked for"). Each state,
/// and the first frames of each open, is a screenshot whose row band is checked for:
/// - a backing: any pixel in the row's left margin (where no row draws) that is not the chat's
///   ground, read from the same pixel before anything opened. A cell or hosting view painting an
///   opaque or stock fill reaches into its margin.
/// - a placeholder color: a run of saturated yellow or red (debug fills, `.yellow`/`.red`
///   stand-ins) larger than an icon.
final class ChatRowFillUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    @MainActor func testRowsOpenAndCloseWithoutPlaceholderFillsMocha() throws { try run(look: "mocha", dark: true) }
    @MainActor func testRowsOpenAndCloseWithoutPlaceholderFillsWallpaper() throws { try run(look: "mocha-wallpaper", dark: true) }
    @MainActor func testRowsOpenAndCloseWithoutPlaceholderFillsSolarized() throws { try run(look: "solarized-bubbles", dark: false) }
    @MainActor func testRowsOpenAndCloseWithoutPlaceholderFillsDefaultLight() throws { try run(look: "default", dark: false) }

    private static let disclosure = NSPredicate(
        format: "label MATCHES %@",
        "^(Thought|Thinking|Read|Ran|Edited|Searched|Wrote|Running|Reading|Worked for|Called|Fetched|Listed|[0-9]+ subagents?).*")

    @MainActor
    private func run(look: String, dark: Bool) throws {
        XCUIDevice.shared.orientation = .portrait
        XCUIDevice.shared.appearance = dark ? .dark : .light
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-demo", "disclosure-chat",
                                "-cmux-mobile-mac-appearance", look]
        app.launch()
        defer { app.terminate() }
        let more = app.navigationBars.buttons["More"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 30), "the pushed agent chat opens\n\(app.debugDescription)")
        settle(1.5)

        let window = app.windows.firstMatch.frame
        let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        let bottom = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
        // The history's Thought is above the newest turn: scroll back until one is on screen.
        let thought = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Thought"))
        for _ in 0..<10 where !(thought.firstMatch.exists && thought.firstMatch.isHittable) {
            top.press(forDuration: 0.05, thenDragTo: bottom)
            settle(0.4)
        }
        XCTAssertTrue(thought.firstMatch.exists, "the demo chat's history has a Thought row\n\(app.debugDescription)")
        settle(0.8)
        let ground = app.screenshot()
        attach(ground, "\(look)-0-collapsed")
        let groundPixels = try XCTUnwrap(RowFillPixels(ground.image))
        let scale = CGFloat(groundPixels.width) / window.width

        // Every disclosure line on screen, top to bottom, by label and place.
        var seen: [(label: String, y: CGFloat)] = []
        let lines = app.descendants(matching: .any).matching(Self.disclosure)
        for index in 0..<lines.count {
            let element = lines.element(boundBy: index)
            guard element.exists, element.isHittable else { continue }
            let frame = element.frame
            guard frame.minY > window.minY + 100, frame.maxY < window.maxY - 140,
                  !seen.contains(where: { abs($0.y - frame.midY) < 8 }) else { continue }
            seen.append((element.label, frame.midY))
        }
        XCTAssertTrue(seen.contains { $0.label.hasPrefix("Thought") }, "the Thought row is one of the lines checked: \(seen)")

        for (step, line) in seen.enumerated() {
            let element = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", line.label))
                .allElementsBoundByIndex.first { $0.exists && abs($0.frame.midY - line.y) < 12 }
            guard let element, element.isHittable else { continue }
            let header = element.frame
            let name = "\(look)-\(step + 1)-\(Self.slug(line.label))"
            element.tap()
            // The first frames of the open: the swap from the native row to its SwiftUI view.
            for frame in 0..<3 {
                let shot = app.screenshot()
                check(shot, ground: groundPixels, scale: scale, header: header, window: window, name: "\(name)-opening-\(frame)")
            }
            settle(0.9)
            let opened = app.screenshot()
            attach(opened, "\(name)-open")
            check(opened, ground: groundPixels, scale: scale, header: header, window: window, name: "\(name)-open")
            // Closed again from the same line, which stays put while its body folds.
            let again = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", line.label))
                .allElementsBoundByIndex.first { $0.exists && abs($0.frame.midY - header.midY) < 12 }
            again?.tap()
            settle(0.9)
            let closed = app.screenshot()
            attach(closed, "\(name)-closed")
            check(closed, ground: groundPixels, scale: scale, header: header, window: window, name: "\(name)-closed")
        }
    }

    /// The band from the tapped line down to the composer, checked for a backing in the left margin
    /// and for placeholder yellow or red anywhere across it.
    @MainActor
    private func check(_ shot: XCUIScreenshot, ground: RowFillPixels, scale: CGFloat, header: CGRect, window: CGRect, name: String) {
        guard let pixels = RowFillPixels(shot.image), pixels.width == ground.width, pixels.height == ground.height else {
            XCTFail("\(name): the screenshot has no pixels or changed size")
            return
        }
        let bandTop = Int((header.minY - 6) * scale)
        let bandBottom = min(pixels.height - 1, Int((window.maxY - 150) * scale))
        guard bandBottom > bandTop else { return }

        // The left margin (2 to 12 pt): rows draw from 20 pt and the find mark from 14 pt.
        var backing = 0
        var firstBacking: (Int, Int)?
        for y in stride(from: bandTop, to: bandBottom, by: 2) {
            for x in stride(from: Int(2 * scale), to: Int(12 * scale), by: 2) {
                if !RowFillPixels.near(pixels[x, y], ground[x, y], tolerance: 14) {
                    backing += 1
                    if firstBacking == nil { firstBacking = (x, y) }
                }
            }
        }
        // Allow a stray antialiased pixel; a backing covers rows of them.
        if backing > 12 {
            attach(shot, "\(name)-FAIL-backing")
            XCTFail("\(name): \(backing) margin pixels are not the chat's ground (first at \(firstBacking.map { "\($0.0),\($0.1)" } ?? "-"): \(pixels[firstBacking?.0 ?? 0, firstBacking?.1 ?? 0]) over \(ground[firstBacking?.0 ?? 0, firstBacking?.1 ?? 0])): a row draws a backing outside its content")
        }

        // Placeholder yellow or red: saturated, bright, in those hues. An icon is at most ~24 pt square.
        var placeholder = 0
        for y in stride(from: bandTop, to: bandBottom, by: 3) {
            for x in stride(from: 0, to: pixels.width, by: 3) where RowFillPixels.isPlaceholderHue(pixels[x, y]) {
                placeholder += 1
            }
        }
        let iconBudget = Int((24 * scale / 3) * (24 * scale / 3))
        if placeholder > iconBudget {
            attach(shot, "\(name)-FAIL-placeholder-color")
            XCTFail("\(name): \(placeholder) sampled pixels are saturated yellow or red (an icon is at most \(iconBudget)): a placeholder color fills part of a row")
        }
    }

    private static func slug(_ label: String) -> String {
        String(label.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }.prefix(28))
    }

    @MainActor
    private func settle(_ seconds: TimeInterval) {
        _ = XCTWaiter().wait(for: [XCTestExpectation(description: "settle")], timeout: seconds)
    }

    @MainActor
    private func attach(_ shot: XCUIScreenshot, _ name: String) {
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

/// A screenshot's RGBA pixels, top row first.
struct RowFillPixels {
    let width: Int
    let height: Int
    private let bytes: [UInt8]

    init?(_ image: UIImage) {
        guard let cg = image.cgImage else { return nil }
        width = cg.width
        height = cg.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: cg.width, height: cg.height, bitsPerComponent: 8,
                                          bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            return true
        }
        guard drawn else { return nil }
        self.bytes = bytes
    }

    subscript(x: Int, y: Int) -> (Int, Int, Int) {
        let px = min(max(x, 0), width - 1)
        let py = min(max(y, 0), height - 1)
        let index = (py * width + px) * 4
        return (Int(bytes[index]), Int(bytes[index + 1]), Int(bytes[index + 2]))
    }

    static func near(_ a: (Int, Int, Int), _ b: (Int, Int, Int), tolerance: Int) -> Bool {
        abs(a.0 - b.0) <= tolerance && abs(a.1 - b.1) <= tolerance && abs(a.2 - b.2) <= tolerance
    }

    /// Saturated, bright yellow or red: what `.yellow`, `.red`, `.systemYellow` and `.systemRed`
    /// draw at full or near-full strength. The Mac themes' pastel reds and yellows (Catppuccin's
    /// #f38ba8, #f9e2af) are far below this saturation.
    static func isPlaceholderHue(_ c: (Int, Int, Int)) -> Bool {
        let r = Double(c.0) / 255, g = Double(c.1) / 255, b = Double(c.2) / 255
        let maxV = max(r, g, b), minV = min(r, g, b)
        guard maxV > 0.6 else { return false }
        let saturation = (maxV - minV) / maxV
        guard saturation > 0.7 else { return false }
        var hue: Double
        if maxV == r { hue = 60 * ((g - b) / (maxV - minV)) } else if maxV == g { hue = 60 * ((b - r) / (maxV - minV) + 2) } else { hue = 60 * ((r - g) / (maxV - minV) + 4) }
        if hue < 0 { hue += 360 }
        return hue < 15 || hue > 345 || (hue > 40 && hue < 65)
    }
}
