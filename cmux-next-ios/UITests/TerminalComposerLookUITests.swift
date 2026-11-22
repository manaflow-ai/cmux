import XCTest

/// Leo, 2026-11-21: "there's still the bug of the composer brightening up
/// when you have >3 lines on ios in terminal mode". The terminal composer's
/// glass field looks the same at every line count: the empty glass beside
/// short lines has the same brightness at 1, 3, 4 and 8 lines (screenshots
/// attached for each).
final class TerminalComposerLookUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    @MainActor
    func testTerminalComposerLookIsConstantAcrossLineCounts() throws {
        try checkLook(name: "terminal-composer")
    }

    /// Reduce Transparency on: the step's `reducetransparency=1` turns it on in the
    /// simulator (com.apple.Accessibility, read back there); launch arguments alone do
    /// not reach UIKit's accessibility settings. Skipped in a step without it.
    @MainActor
    func testTerminalComposerLookIsConstantWithReduceTransparency() throws {
        try XCTSkipUnless(Self.stepTurnedOn("reducetransparency"), "run the step with reducetransparency=1")
        XCTAssertTrue(UIAccessibility.isReduceTransparencyEnabled, "Reduce Transparency is on in this simulator")
        try checkLook(name: "reduce-transparency", arguments: ["-UIAccessibilityReduceTransparencyEnabled", "YES"],
                      note: "isReduceTransparencyEnabled=\(UIAccessibility.isReduceTransparencyEnabled)")
    }

    /// Increase Contrast on (`increasecontrast=1` in the step, as above).
    @MainActor
    func testTerminalComposerLookIsConstantWithIncreaseContrast() throws {
        try XCTSkipUnless(Self.stepTurnedOn("increasecontrast"), "run the step with increasecontrast=1")
        XCTAssertTrue(UIAccessibility.isDarkerSystemColorsEnabled, "Increase Contrast is on in this simulator")
        try checkLook(name: "increase-contrast", arguments: ["-UIAccessibilityDarkerSystemColorsEnabled", "YES"],
                      note: "isDarkerSystemColorsEnabled=\(UIAccessibility.isDarkerSystemColorsEnabled)")
    }

    /// A light backdrop: the terminal demo's page in a light terminal theme (the Mac's
    /// Solarized Light, `-CmuxMobileTerminalDemoLight`, this launch only), the same
    /// TerminalTabPage and composer as a workspace's tab. The terminal above the field
    /// is checked light, so the run is not a dark one by mistake.
    @MainActor
    func testTerminalComposerLookIsConstantOnALightTerminal() throws {
        try checkLook(name: "light-terminal",
                      arguments: ["-CmuxMobileTerminalDemo", "-CmuxMobileTerminalDemoEmbedded",
                                  "-CmuxMobileTerminalDemoPhases", "none", "-CmuxMobileTerminalDemoLight"],
                      demo: false, lightBackdrop: true)
    }

    private static func stepTurnedOn(_ setting: String) -> Bool {
        (ProcessInfo.processInfo.environment["CMUX_SIM_A11Y"] ?? "").split(separator: " ").contains { $0 == setting }
    }

    /// Types 1 to 8 lines, measures the field's empty glass at 1, 3, 4 and 8, attaches
    /// each screenshot and the numbers, and checks 3, 4 and 8 against 1.
    @MainActor
    private func checkLook(name: String, arguments: [String] = [], note: String = "", demo: Bool = true,
                           lightBackdrop: Bool = false) throws {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES"]
        if demo { app.launchArguments += ["-cmux-mobile-demo", "ws-terminal-idle"] }
        app.launchArguments += arguments
        app.launch()
        defer { app.terminate() }
        let field = app.textViews["terminal.composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 20), "composer field\n\(app.debugDescription)")
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), "the keyboard comes up")

        var lumas: [Int: Double] = [:]
        var backdrops: [Int: Double] = [:]
        field.typeText("l1")
        for count in 1...8 {
            if count > 1 { field.typeText("\nl\(count)") }
            guard [1, 3, 4, 8].contains(count) else { continue }
            // Let the glass settle after the field's height change.
            Thread.sleep(forTimeInterval: 0.8)
            let shot = app.screenshot()
            let attachment = XCTAttachment(screenshot: shot)
            attachment.name = "\(name)-\(count)-lines"
            attachment.lifetime = .keepAlways
            add(attachment)
            let luma = try Self.meanLuma(shot.image, in: Self.emptyGlass(field.frame))
            lumas[count] = luma
            backdrops[count] = try Self.meanLuma(shot.image, in: Self.backdrop(field.frame))
            print("composer-look \(name) lines=\(count) frame=\(field.frame) luma=\(String(format: "%.2f", luma))")
        }
        // The numbers as a text attachment too: a UI test's print never
        // reaches the step's exported logs, its attachments do.
        var lines = lumas.sorted { $0.key < $1.key }.map {
            "composer-look \(name) lines=\($0.key) luma=\(String(format: "%.2f", $0.value)) backdrop=\(String(format: "%.2f", backdrops[$0.key] ?? -1))"
        }
        if !note.isEmpty { lines.append("composer-look \(name) \(note)") }
        let numbers = XCTAttachment(string: lines.joined(separator: "\n"))
        numbers.name = "\(name == "terminal-composer" ? "composer-look" : name)-numbers"
        numbers.lifetime = .keepAlways
        add(numbers)
        let one = try XCTUnwrap(lumas[1])
        for count in [3, 4, 8] {
            let luma = try XCTUnwrap(lumas[count])
            XCTAssertEqual(luma, one, accuracy: 3, "\(name): the field's glass at \(count) lines is as bright as at 1 line")
        }
        if lightBackdrop {
            for (count, backdrop) in backdrops {
                XCTAssertGreaterThan(backdrop, 150, "\(name): the terminal above the field is light at \(count) lines")
            }
        }
    }

    /// The terminal's right edge near the top of the page, clear of the toolbar, the
    /// prompt's text and the dock: its background.
    private static func backdrop(_ field: CGRect) -> CGRect {
        CGRect(x: field.maxX - 44, y: 140, width: 36, height: 24)
    }

    /// The field's empty glass right of the short lines: inside the text
    /// view, clear of its rounded corners and of the text.
    private static func emptyGlass(_ field: CGRect) -> CGRect {
        CGRect(x: field.maxX - 44, y: field.minY + 12, width: 36, height: max(8, field.height - 24))
    }

    /// Mean Rec. 709 luma (0-255) of `rect` (points) in a screenshot.
    private static func meanLuma(_ image: UIImage, in rect: CGRect) throws -> Double {
        let cg = try XCTUnwrap(image.cgImage)
        let scale = CGFloat(cg.width) / image.size.width
        let pixels = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale).integral
        let crop = try XCTUnwrap(cg.cropping(to: pixels))
        let width = crop.width, height = crop.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        XCTAssertTrue(drawn)
        var sum = 0.0
        for index in stride(from: 0, to: data.count, by: 4) {
            sum += 0.2126 * Double(data[index]) + 0.7152 * Double(data[index + 1]) + 0.0722 * Double(data[index + 2])
        }
        return sum / Double(width * height)
    }
}
