import Foundation
import Testing

/// Mac Screen never makes macOS ask for, check or use a grant of the cmux app itself: every
/// session is captured, and every Screen Recording and Accessibility request is made, by cmux
/// Computer Use (its host and Screen Sharing worker), so System Settings lists one app and a
/// grant never relaunches cmux (Lawrence, 2026-11-17: "ensure screen sharing + computer use uses
/// same app for permissions"). This fails when any source of CmuxNextMacScreen calls an API that
/// prompts for, reads or needs this process's Screen Recording, Accessibility or Input Monitoring.
@Suite struct MacScreenNoAppGrantTests {
    /// The APIs that prompt for, read or need this process's own TCC grants, and in-process capture.
    static let forbidden = [
        "CGRequestScreenCaptureAccess", "CGPreflightScreenCaptureAccess",
        "AXIsProcessTrustedWithOptions", "AXIsProcessTrusted",
        "CGRequestPostEventAccess", "CGPreflightPostEventAccess",
        "CGRequestListenEventAccess", "CGPreflightListenEventAccess", "IOHIDRequestAccess", "IOHIDCheckAccess",
        "SCShareableContent", "SCStream", "SCScreenshotManager", "SCContentSharingPicker", "SCContentFilter",
        "CGWindowListCreateImage", "CGDisplayCreateImage", "CGDisplayStream",
        "ScreenCaptureBackend", "ScreenStreamHost", "tapCreate", "CGEventTapCreate", "AVCaptureScreenInput",
    ]

    static var sources: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/CmuxNextMacScreen", directoryHint: .isDirectory)
    }

    /// `text` without its comments (`//` to the end of a line, and `/* ... */`); string literals stay.
    static func code(_ text: String) -> String {
        var code = text.replacingOccurrences(of: #"/\*[\s\S]*?\*/"#, with: "", options: .regularExpression)
        code = code.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            guard let range = line.range(of: "//") else { return String(line) }
            return String(line[..<range.lowerBound])
        }.joined(separator: "\n")
        return code
    }

    /// The forbidden names `code` uses (whole identifiers only).
    static func uses(_ code: String) -> [String] {
        forbidden.filter { name in
            code.range(of: #"(?<![A-Za-z0-9_])"# + NSRegularExpression.escapedPattern(for: name) + #"(?![A-Za-z0-9_])"#,
                       options: .regularExpression) != nil
        }
    }

    @Test func noMacScreenSourceAsksForOrUsesTheAppsOwnGrants() throws {
        let files = try #require(FileManager.default.enumerator(at: Self.sources, includingPropertiesForKeys: nil))
        var found: [String] = []
        var scanned = 0
        for case let file as URL in files where file.pathExtension == "swift" {
            scanned += 1
            let names = Self.uses(Self.code(try String(contentsOf: file, encoding: .utf8)))
            if !names.isEmpty { found.append("\(file.lastPathComponent): \(names.joined(separator: ", "))") }
        }
        #expect(scanned > 20, "CmuxNextMacScreen's sources were not found at \(Self.sources.path)")
        #expect(found.isEmpty, "Mac Screen goes through cmux Computer Use, never the app's own grants:\n\(found.joined(separator: "\n"))")
    }

    /// The scan itself: a call is caught, a comment or a longer identifier is not.
    @Test func theScanSeesCallsAndSkipsComments() {
        #expect(Self.uses(Self.code("let ok = CGRequestScreenCaptureAccess()")) == ["CGRequestScreenCaptureAccess"])
        #expect(Self.uses(Self.code("_ = AXIsProcessTrustedWithOptions(options) // prompt")) == ["AXIsProcessTrustedWithOptions"])
        #expect(Self.uses(Self.code("// CGRequestScreenCaptureAccess() was here\n/* SCStream */ let x = 1")).isEmpty)
        #expect(Self.uses(Self.code("let a = SCStreamConfigurationLike()")).isEmpty)
        #expect(Self.uses(Self.code("let s = ScreenStreamHost(name: n)")) == ["ScreenStreamHost"])
    }
}
