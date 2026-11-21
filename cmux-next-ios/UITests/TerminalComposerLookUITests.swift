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
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-demo", "ws-terminal-idle"]
        app.launch()
        defer { app.terminate() }
        let field = app.textViews["terminal.composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 20), "composer field\n\(app.debugDescription)")
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), "the keyboard comes up")

        var lumas: [Int: Double] = [:]
        field.typeText("l1")
        for count in 1...8 {
            if count > 1 { field.typeText("\nl\(count)") }
            guard [1, 3, 4, 8].contains(count) else { continue }
            // Let the glass settle after the field's height change.
            Thread.sleep(forTimeInterval: 0.8)
            let shot = app.screenshot()
            let attachment = XCTAttachment(screenshot: shot)
            attachment.name = "terminal-composer-\(count)-lines"
            attachment.lifetime = .keepAlways
            add(attachment)
            let luma = try Self.meanLuma(shot.image, in: Self.emptyGlass(field.frame))
            lumas[count] = luma
            print("composer-look lines=\(count) frame=\(field.frame) luma=\(String(format: "%.2f", luma))")
        }
        // The numbers as a text attachment too: a UI test's print never
        // reaches the step's exported logs, its attachments do.
        let numbers = XCTAttachment(string: lumas.sorted { $0.key < $1.key }
            .map { "composer-look lines=\($0.key) luma=\(String(format: "%.2f", $0.value))" }.joined(separator: "\n"))
        numbers.name = "composer-look-numbers"
        numbers.lifetime = .keepAlways
        add(numbers)
        let one = try XCTUnwrap(lumas[1])
        for count in [3, 4, 8] {
            let luma = try XCTUnwrap(lumas[count])
            XCTAssertEqual(luma, one, accuracy: 3, "the field's glass at \(count) lines is as bright as at 1 line")
        }
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
