import CoreGraphics
import UIKit
import XCTest

/// The lean terminal against the PTY terminal on the phone, pixel for pixel, case by case
/// (Leo, 2026-11-17: "how's the lean terminal view on phone? proven upholding behaviour yet?
/// headers left right end of terminal lines etc?").
///
/// Each case launches the app's hybrid bench (`AgentCLIHybridBench`, still mode) twice at the
/// same daemon frame of one session: once drawn from the PTY's bytes, once from lean frames.
/// The bench reports where the Mac's grid is drawn (`hybrid-bench.geometry`: window points,
/// from the terminal screen's own layout), so the comparison covers exactly the grid's pixels
/// on screen, its first row (an agent CLI's header) and its first and last column included.
/// A grid wider than the phone is compared panned to its first column and to its last.
///
/// Pixels: a pixel differs when a channel differs by more than 24 of 255 (GPU blend rounding).
/// The cursor's cell is left out of the pixel count (it blinks) and checked instead by place:
/// both cursors must be the same rect. A case passes when at most 0.05% of the grid's pixels
/// differ and at most 0.1% of each named band (the first three rows, the first column, the
/// last column). Every case attaches its PTY still, its lean still and the diff (red: differs,
/// yellow: the compared grid's outline) and prints one `PIXEL_MATRIX` line.
///
/// Sessions: the three recorded agent CLI sessions (Claude Code, Codex, opencode), the recorded
/// bash session (`shell-bash-5.2`: wide and combined glyphs, the alternate screen, a resize to
/// 80x24 and back) and `pixel-matrix`, written for this matrix
/// (cmux-agent-cli-render `tests/fixtures/pixel-matrix/make_fixture.py`).
final class AgentCLIHybridPixelMatrixUITests: XCTestCase {
    static let channelTolerance = 24
    static let maxGridShare = 0.0005
    static let maxBandShare = 0.001
    @MainActor static var warmedUp = false

    override func setUp() {
        continueAfterFailure = true
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
    }

    // MARK: Rows

    /// Row 1: the agent CLIs' header rows (and their whole screens) at three frames each.
    @MainActor
    func testRow1AgentHeaders() throws {
        for name in ["claude-code-2.1.310", "codex-0.164.0", "opencode-1.19.5"] {
            for atMs in try stills(name) {
                compare(row: 1, name, atMs: atMs)
            }
        }
    }

    /// Row 2: the first and the last column of every row, panned to each edge.
    @MainActor
    func testRow2FirstAndLastColumns() throws {
        let edges = try still("pixel-matrix", moment: "edges")
        compare(row: 2, "pixel-matrix", atMs: edges, label: "edges")
        compare(row: 2, "pixel-matrix", atMs: edges, label: "edges", panEnd: true)
        for name in ["claude-code-2.1.310", "codex-0.164.0", "opencode-1.19.5"] {
            compare(row: 2, name, atMs: try stills(name).last!, label: "last", panEnd: true)
        }
    }

    /// Row 3: a line wrapped over three rows, one of exactly 100 columns, a styled run across
    /// the wrap; and bash's long line at 80 columns.
    @MainActor
    func testRow3WrappedLines() throws {
        let wrapped = try still("pixel-matrix", moment: "wrapped")
        compare(row: 3, "pixel-matrix", atMs: wrapped, label: "wrapped")
        compare(row: 3, "pixel-matrix", atMs: wrapped, label: "wrapped", panEnd: true)
        compare(row: 3, "shell-bash-5.2", atMs: try still("shell-bash-5.2", moment: "wrapped"), label: "wrapped")
    }

    /// Row 4: CJK, emoji (skin tone, flag), fullwidth and combined glyphs, wide glyphs that
    /// wrap at the right edge and one that ends exactly on it.
    @MainActor
    func testRow4WideGlyphs() throws {
        let wide = try still("pixel-matrix", moment: "wide")
        compare(row: 4, "pixel-matrix", atMs: wide, label: "wide")
        compare(row: 4, "pixel-matrix", atMs: wide, label: "wide", panEnd: true)
        compare(row: 4, "shell-bash-5.2", atMs: try still("shell-bash-5.2", moment: "unicode"), label: "unicode")
    }

    /// Row 5: a full-screen box-drawing app: header and footer bars, borders on every edge.
    @MainActor
    func testRow5BoxDrawingApp() throws {
        let box = try still("pixel-matrix", moment: "box")
        compare(row: 5, "pixel-matrix", atMs: box, label: "box")
        compare(row: 5, "pixel-matrix", atMs: box, label: "box", panEnd: true)
    }

    /// Row 6: into the alternate screen and back out (the page's layout must follow it too).
    @MainActor
    func testRow6AlternateScreenInAndOut() throws {
        compare(row: 6, "pixel-matrix", atMs: try still("pixel-matrix", moment: "box"), label: "alt-in", sameLayout: true)
        compare(row: 6, "pixel-matrix", atMs: try still("pixel-matrix", moment: "left_alt"), label: "alt-out", sameLayout: true)
        compare(row: 6, "shell-bash-5.2", atMs: try still("shell-bash-5.2", moment: "alt"), label: "alt-in", sameLayout: true)
        compare(row: 6, "shell-bash-5.2", atMs: try still("shell-bash-5.2", moment: "before_drop"), label: "alt-out",
                sameLayout: true)
    }

    /// Row 7: the cursor's place: inside a full-screen app, on its last column, at a prompt.
    @MainActor
    func testRow7CursorPosition() throws {
        compare(row: 7, "pixel-matrix", atMs: try still("pixel-matrix", moment: "cursor_mid"), label: "cursor-mid")
        compare(row: 7, "pixel-matrix", atMs: try still("pixel-matrix", moment: "cursor_edge"), label: "cursor-edge",
                panEnd: true)
        compare(row: 7, "pixel-matrix", atMs: try still("pixel-matrix", moment: "done"), label: "cursor-prompt")
        compare(row: 7, "claude-code-2.1.310", atMs: try stills("claude-code-2.1.310").last!, label: "cursor")
    }

    /// Row 8: the Mac's terminal resized mid-stream (100x32 to 80x24 and back), and the phone
    /// rotated with a still on screen.
    @MainActor
    func testRow8ResizeAndRotate() throws {
        compare(row: 8, "shell-bash-5.2", atMs: try still("shell-bash-5.2", moment: "small"), label: "80x24")
        compare(row: 8, "shell-bash-5.2", atMs: try still("shell-bash-5.2", moment: "done"), label: "100x32-again")
        let rotate: (XCUIApplication) -> Void = { _ in XCUIDevice.shared.orientation = .landscapeLeft }
        compare(row: 8, "pixel-matrix", atMs: try still("pixel-matrix", moment: "edges"), label: "landscape", between: rotate)
        compare(row: 8, "opencode-1.19.5", atMs: try stills("opencode-1.19.5").last!, label: "landscape", between: rotate)
    }

    /// Row 9: the app sent to the background and brought back with a still on screen.
    @MainActor
    func testRow9ResumeAfterBackground() throws {
        let background: (XCUIApplication) -> Void = { app in
            XCUIDevice.shared.press(.home)
            Self.pause(2)
            app.activate()
        }
        compare(row: 9, "pixel-matrix", atMs: try still("pixel-matrix", moment: "box"), label: "background", between: background)
        compare(row: 9, "claude-code-2.1.310", atMs: try stills("claude-code-2.1.310").last!, label: "background",
                between: background)
    }

    // MARK: Sessions

    /// The session file: bundled into this test target (`project.yml`), so the matrix runs on a
    /// device too; the checkout's copy when the bundle has none.
    private func fixtureData(_ name: String) throws -> Data {
        if let url = Bundle(for: Self.self).url(forResource: name, withExtension: "json") {
            return try Data(contentsOf: url)
        }
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("verify/agent-cli-hybrid/\(name).json")
        return try Data(contentsOf: path)
    }

    /// The session as the app takes it from its environment (`AgentCLIHybridBench`): LZFSE, base64.
    private func packedFixture(_ name: String) throws -> String {
        try (fixtureData(name) as NSData).compressed(using: .lzfse).base64EncodedString()
    }

    private func session(_ name: String) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: fixtureData(name)) as? [String: Any])
    }

    private func leanFrameTimes(_ name: String) throws -> [Int] {
        try XCTUnwrap(try session(name)["lean_frames"] as? [[Any]]).compactMap { $0.first as? Int }
    }

    /// Three daemon frames after the attach: a quarter in, halfway, the last.
    private func stills(_ name: String) throws -> [Int] {
        let frames = try leanFrameTimes(name)
        XCTAssertGreaterThan(frames.count, 8, name)
        return [frames[frames.count / 4], frames[frames.count / 2], frames[frames.count - 1]]
    }

    /// The last daemon frame at or before the session's `moment`.
    private func still(_ name: String, moment: String) throws -> Int {
        let moments = try XCTUnwrap(try session(name)["moments"] as? [[String: Any]])
        let at = try XCTUnwrap(moments.first { $0["name"] as? String == moment }?["t_ms"] as? Int, "\(name): no \(moment)")
        return try XCTUnwrap(try leanFrameTimes(name).last { $0 <= at }, "\(name) \(moment): no frame before it")
    }

    // MARK: Stills

    struct Still {
        let image: UIImage
        let grid: CGRect
        let cursor: CGRect?
        /// One cell of the Mac's grid (points).
        let cell: CGSize
        let fullScreen: Bool
        let alternate: Bool
        let scale: CGFloat
    }

    static func pause(_ seconds: TimeInterval) {
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "settle")], timeout: seconds)
    }

    @MainActor
    private func shot(_ name: String, _ mode: String, _ atMs: Int, panEnd: Bool,
                      between: ((XCUIApplication) -> Void)?) -> Still? {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        guard let packed = try? packedFixture(name) else {
            XCTFail("\(name): no session file")
            return nil
        }
        app.launchEnvironment["CMUX_HYBRID_BENCH_SESSION_LZFSE"] = packed
        app.launchArguments += [
            "-CmuxMobileHybridBench",
            "-CmuxMobileHybridBenchMode", mode, "-CmuxMobileHybridBenchStillMs", String(atMs),
            "-CmuxMobileHybridBenchPan", panEnd ? "end" : "start",
        ]
        app.launch()
        defer { app.terminate() }
        let result = app.staticTexts["hybrid-bench.result"]
        guard result.waitForExistence(timeout: 120) else {
            XCTFail("\(name) \(mode) \(atMs): no still")
            return nil
        }
        XCTAssertFalse(result.label.contains("\"error\""), result.label)
        if let between {
            between(app)
            // The page lays out again (and the bench's geometry follows it every 200 ms).
            Self.pause(2)
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "\(name) \(mode): back in the foreground")
        }
        let label = app.staticTexts["hybrid-bench.geometry"]
        guard label.waitForExistence(timeout: 10),
              let data = label.label.data(using: .utf8),
              let geometry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let grid = Self.rect(geometry["grid"]), let cell = geometry["cell"] as? [Double], cell.count == 2 else {
            XCTFail("\(name) \(mode) \(atMs): no geometry")
            return nil
        }
        let shot = XCUIScreen.main.screenshot()
        return Still(image: shot.image, grid: grid, cursor: Self.rect(geometry["cursor"]), cell: CGSize(width: cell[0], height: cell[1]),
                     fullScreen: geometry["fullScreen"] as? Bool ?? false, alternate: geometry["alternate"] as? Bool ?? false,
                     scale: CGFloat(geometry["scale"] as? Double ?? Double(shot.image.scale)))
    }

    static func rect(_ value: Any?) -> CGRect? {
        guard let v = value as? [Double], v.count == 4 else { return nil }
        return CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
    }

    private func attach(_ image: UIImage, _ name: String) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// One case: the PTY's and the lean frames' stills of `name` at `atMs`, compared.
    @MainActor
    private func compare(row: Int, _ name: String, atMs: Int, label: String = "", panEnd: Bool = false,
                         sameLayout: Bool = false, between: ((XCUIApplication) -> Void)? = nil) {
        if !Self.warmedUp {
            // The first launch on a fresh simulator draws nothing for its first seconds.
            Self.warmedUp = true
            _ = shot(name, "pty", atMs, panEnd: false, between: nil)
        }
        let id = "row\(row)-\(name)-\(label.isEmpty ? "" : label + "-")\(atMs)ms\(panEnd ? "-end" : "")"
        guard let pty = shot(name, "pty", atMs, panEnd: panEnd, between: between),
              let lean = shot(name, "lean", atMs, panEnd: panEnd, between: between) else { return }
        var failures: [String] = []
        if pty.grid != lean.grid { failures.append("grid placed at \(lean.grid) instead of \(pty.grid)") }
        if pty.cursor != lean.cursor {
            failures.append("cursor at \(lean.cursor.map { "\($0)" } ?? "none") instead of \(pty.cursor.map { "\($0)" } ?? "none")")
        }
        if sameLayout, pty.fullScreen != lean.fullScreen || pty.alternate != lean.alternate {
            failures.append("layout full-screen \(lean.fullScreen) alternate \(lean.alternate), PTY \(pty.fullScreen) \(pty.alternate)")
        }
        guard let diff = Self.diff(pty, lean) else {
            XCTFail("\(id): unreadable screenshots")
            return
        }
        attach(pty.image, "\(id)-pty")
        attach(lean.image, "\(id)-lean")
        attach(diff.image, "\(id)-diff")
        let gridShare = Double(diff.differing) / Double(max(diff.compared, 1))
        if gridShare > Self.maxGridShare { failures.append("\(diff.differing) of \(diff.compared) grid pixels differ") }
        for band in diff.bands where band.compared > 0 && Double(band.differing) / Double(band.compared) > Self.maxBandShare {
            failures.append("\(band.name): \(band.differing) of \(band.compared) pixels differ")
        }
        let bands = diff.bands.map { "\($0.name)=\($0.differing)/\($0.compared)" }.joined(separator: " ")
        let line = "PIXEL_MATRIX row=\(row) case=\(id) pass=\(failures.isEmpty) grid=\(diff.differing)/\(diff.compared) "
            + "share=\(String(format: "%.4f", gridShare * 100))% \(bands) fullScreen=\(pty.fullScreen)/\(lean.fullScreen) "
            + "alternate=\(pty.alternate)/\(lean.alternate)" + (failures.isEmpty ? "" : " why=\(failures.joined(separator: "; "))")
        print(line)
        let summary = XCTAttachment(string: line)
        summary.name = "\(id)-summary"
        summary.lifetime = .keepAlways
        add(summary)
        XCTAssertTrue(failures.isEmpty, line)
    }

    // MARK: Pixels

    /// RGBA pixels of `image`, drawn upright.
    static func pixels(_ image: UIImage) -> (bytes: [UInt8], width: Int, height: Int)? {
        let width = Int((image.size.width * image.scale).rounded())
        let height = Int((image.size.height * image.scale).rounded())
        guard width > 0, height > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            // UIKit's drawing honors the image's orientation (a landscape screenshot).
            UIGraphicsPushContext(context)
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: image.scale, y: -image.scale)
            image.draw(at: .zero)
            UIGraphicsPopContext()
            return true
        }
        return drawn ? (bytes, width, height) : nil
    }

    struct Band {
        let name: String
        var differing = 0
        var compared = 0
    }

    /// The grid's pixels of `a` and `b` that differ (the cursor cells left out), overall and per
    /// band, and an image of them: red where they differ, `b` dimmed elsewhere, the grid's
    /// outline yellow.
    static func diff(_ a: Still, _ b: Still) -> (differing: Int, compared: Int, bands: [Band], image: UIImage)? {
        guard let first = pixels(a.image), let second = pixels(b.image), first.width == second.width,
              first.height == second.height else { return nil }
        let (width, height) = (first.width, first.height)
        let scale = a.scale
        func px(_ r: CGRect) -> (x0: Int, y0: Int, x1: Int, y1: Int) {
            (Int((r.minX * scale).rounded()), Int((r.minY * scale).rounded()),
             Int((r.maxX * scale).rounded()), Int((r.maxY * scale).rounded()))
        }
        let grid = px(a.grid)
        let (x0, y0) = (max(0, grid.x0), max(0, grid.y0))
        let (x1, y1) = (min(width, grid.x1), min(height, grid.y1))
        let cursors = [a.cursor, b.cursor].compactMap { $0 }.map { px($0.insetBy(dx: -1, dy: -1)) }
        // Cells of the Mac's grid: rows and columns in pixels.
        var bands = [Band(name: "header"), Band(name: "firstColumn"), Band(name: "lastColumn")]
        let cellHeight = Double(a.cell.height * scale)
        let headerBottom = grid.y0 + Int((cellHeight * 3).rounded())
        let cellWidth = Double(a.cell.width * scale)
        let firstColumnRight = grid.x0 + Int(cellWidth.rounded())
        let lastColumnLeft = grid.x1 - Int(cellWidth.rounded())
        var out = [UInt8](repeating: 0, count: width * height * 4)
        var differing = 0
        var compared = 0
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let inGrid = x >= x0 && x < x1 && y >= y0 && y < y1
                let inCursor = cursors.contains { x >= $0.x0 && x < $0.x1 && y >= $0.y0 && y < $0.y1 }
                let counted = inGrid && !inCursor
                let delta = max(abs(Int(first.bytes[i]) - Int(second.bytes[i])),
                                abs(Int(first.bytes[i + 1]) - Int(second.bytes[i + 1])),
                                abs(Int(first.bytes[i + 2]) - Int(second.bytes[i + 2])))
                let differs = counted && delta > channelTolerance
                if counted {
                    compared += 1
                    if differs { differing += 1 }
                    for (k, inBand) in [y < headerBottom, x < firstColumnRight, x >= lastColumnLeft].enumerated() where inBand {
                        bands[k].compared += 1
                        if differs { bands[k].differing += 1 }
                    }
                }
                let edge = inGrid && (x == x0 || x == x1 - 1 || y == y0 || y == y1 - 1)
                if differs {
                    out[i] = 255; out[i + 1] = 0; out[i + 2] = 0
                } else if edge {
                    out[i] = 255; out[i + 1] = 220; out[i + 2] = 0
                } else {
                    for c in 0..<3 { out[i + c] = second.bytes[i + c] / 3 }
                }
                out[i + 3] = 255
            }
        }
        let image: UIImage? = out.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let cg = context.makeImage() else { return nil }
            return UIImage(cgImage: cg)
        }
        guard let image else { return nil }
        return (differing, compared, bands, image)
    }
}
