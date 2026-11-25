import CoreGraphics
import UIKit
import XCTest

/// Proof 3 of the lean decoder (Leo, 2026-11-16: "prove it correct"): simulator screenshots of
/// each agent CLI session at the same daemon frames, drawn from the PTY's bytes and from lean
/// frames (`AgentCLIHybridBench` still mode), diffed here pixel by pixel.
///
/// Tolerance: a pixel differs when a channel differs by more than 24 of 255, and a pair fails
/// when more than 0.1% of the compared pixels differ (about ten terminal cells of a 100-column
/// grid on an iPhone). Both images come from the same Ghostty renderer drawing the same cells in
/// the same font, so glyph antialiasing is identical; the channel tolerance covers GPU blend
/// rounding and the bench's 1%-opacity result label, the share covers the cursor's blink phase
/// (one cell, 0.04-0.05% on the fleet). Breaking one SGR code (bold drawn dim) reads 0.21-0.46%.
/// Compared: the terminal grid from its second row to just above the home indicator. Left out:
/// the status bar, the navigation bar and the grid's first row under it, which iOS's scroll
/// edge blur blends with what lies above the grid: PTY scrollback, which lean frames do not
/// carry (scrollback is not part of the hybrid contract). The first row is still checked cell
/// for cell by `AgentCLIHybridProofTests`. Each pair and its diff image (red: differs) are kept
/// as attachments.
final class AgentCLIHybridPixelDiffUITests: XCTestCase {
    static let sessions = ["claude-code-2.1.310", "codex-0.164.0", "opencode-1.19.5"]
    static let channelTolerance = 24
    static let maxDifferingShare = 0.001

    override func setUp() {
        continueAfterFailure = true
    }

    private func fixture(_ name: String) -> String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("verify/agent-cli-hybrid/\(name).json").path
    }

    /// Three daemon frames of the session after its attach: a quarter in, halfway, the last.
    private func stills(_ name: String) throws -> [Int] {
        let data = try Data(contentsOf: URL(fileURLWithPath: fixture(name)))
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let frames = try XCTUnwrap(root["lean_frames"] as? [[Any]]).compactMap { $0.first as? Int }
        XCTAssertGreaterThan(frames.count, 8, name)
        return [frames[frames.count / 4], frames[frames.count / 2], frames[frames.count - 1]]
    }

    @MainActor
    private func still(_ name: String, _ mode: String, _ atMs: Int) -> XCUIScreenshot? {
        let app = XCUIApplication()
        app.launchArguments += [
            "-CmuxMobileHybridBench", "-CmuxMobileHybridBenchFile", fixture(name),
            "-CmuxMobileHybridBenchMode", mode, "-CmuxMobileHybridBenchStillMs", String(atMs),
        ]
        app.launch()
        let result = app.staticTexts["hybrid-bench.result"]
        guard result.waitForExistence(timeout: 120) else {
            XCTFail("\(name) \(mode) \(atMs): no still")
            app.terminate()
            return nil
        }
        XCTAssertFalse(result.label.contains("\"error\""), result.label)
        let shot = XCUIScreen.main.screenshot()
        app.terminate()
        return shot
    }

    private func attach(_ image: UIImage, _ name: String) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testLeanFramesLookLikeThePTYAtTheSameFrames() throws {
        // The first launch on a fresh simulator draws nothing for its first seconds.
        _ = still(Self.sessions[0], "pty", try stills(Self.sessions[0])[0])
        var report: [String] = []
        for name in Self.sessions {
            for atMs in try stills(name) {
                guard let pty = still(name, "pty", atMs), let lean = still(name, "lean", atMs) else { continue }
                let diff = try XCTUnwrap(Self.diff(pty.image, lean.image), "\(name) \(atMs): unreadable screenshots")
                let label = "\(name)-\(atMs)ms"
                attach(pty.image, "\(label)-pty")
                attach(lean.image, "\(label)-lean")
                attach(diff.image, "\(label)-diff")
                let share = Double(diff.differing) / Double(max(diff.compared, 1))
                report.append("\(label): \(diff.differing) of \(diff.compared) pixels differ (\(String(format: "%.4f", share * 100))%)")
                XCTAssertLessThanOrEqual(share, Self.maxDifferingShare, "\(label): \(diff.differing) pixels differ")
            }
        }
        print("HYBRID_PROOF pixel " + report.joined(separator: "; "))
        let summary = XCTAttachment(string: report.joined(separator: "\n"))
        summary.name = "pixel-diff-summary"
        summary.lifetime = .keepAlways
        add(summary)
    }

    /// RGBA pixels of `image`.
    static func pixels(_ image: UIImage) -> (bytes: [UInt8], width: Int, height: Int)? {
        guard let cg = image.cgImage else { return nil }
        let (width, height) = (cg.width, cg.height)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? (bytes, width, height) : nil
    }

    /// The pixels of `a` and `b` that differ (rows of the status and navigation bars and the home
    /// indicator left out), and an image of them: red where they differ, `b` dimmed elsewhere.
    static func diff(_ a: UIImage, _ b: UIImage) -> (differing: Int, compared: Int, image: UIImage)? {
        guard let first = pixels(a), let second = pixels(b), first.width == second.width, first.height == second.height else {
            return nil
        }
        let (width, height) = (first.width, first.height)
        let top = Int(Double(height) * 0.155)
        let bottom = height - Int(Double(height) * 0.03)
        var out = [UInt8](repeating: 0, count: width * height * 4)
        var differing = 0
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let delta = max(abs(Int(first.bytes[i]) - Int(second.bytes[i])),
                                abs(Int(first.bytes[i + 1]) - Int(second.bytes[i + 1])),
                                abs(Int(first.bytes[i + 2]) - Int(second.bytes[i + 2])))
                let counted = y >= top && y < bottom
                if counted, delta > channelTolerance {
                    differing += 1
                    out[i] = 255
                    out[i + 1] = 0
                    out[i + 2] = 0
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
        return (differing, width * (bottom - top), image)
    }
}
