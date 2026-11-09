import Foundation
import Testing

/// The phone app and the shared packages draw no system spinner: `ProgressView()` (and
/// `ProgressView("…")`), `UIActivityIndicatorView` and `NSProgressIndicator` turn at the system's
/// own speed, not the shared spinner period (Leo 2026-11-07: "Let's have all our spinners go at that
/// speed."). They use `CmuxSpinner` / `CmuxSpinnerView`. A determinate bar (`ProgressView(value:)`,
/// a `.linear` style) is not a spinner. The Mac app's own sources (Packages/macOS/CmuxNext) have the
/// ast-grep rule no-ad-hoc-spinner instead.
@Suite struct NoSystemSpinnerTests {
    // feat-imsg-parity-gui migrates only CmuxConversation; feat-cmux-next's copy guards every iOS root.
    private static let roots = ["Packages/iOS/CmuxConversation"]
    private static let skipped = ["/Tests/", "/UITests/", "/.build/", "/CmuxSpinner/"]
    private static var spinner: Regex<Substring> {
        #/ProgressView\(\s*\)|ProgressView\(\s*"|UIActivityIndicatorView\(|NSProgressIndicator\(/#
    }

    private static func repoRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { url.deleteLastPathComponent() }
        return url
    }

    /// Findings in one file's text, as "line: text"; comments are not code.
    static func findings(in text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).enumerated().compactMap { index, raw in
            let line = raw.split(separator: "//", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            guard line.contains(spinner), !line.contains(".progressViewStyle(.linear") else { return nil }
            return "\(index + 1): \(raw.trimmingCharacters(in: .whitespaces))"
        }
    }

    @Test func noSystemSpinners() throws {
        let root = Self.repoRoot()
        var found: [String] = []
        for folder in Self.roots {
            let base = root.appendingPathComponent(folder)
            guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                let path = url.path
                guard !Self.skipped.contains(where: path.contains) else { continue }
                let text = try String(contentsOf: url, encoding: .utf8)
                let relative = String(path.dropFirst(root.path.count + 1))
                found += Self.findings(in: text).map { "\(relative):\($0)" }
            }
        }
        #expect(found.isEmpty, "use CmuxSpinner / CmuxSpinnerView: \(found.joined(separator: "\n"))")
    }

    @Test func catchesEveryKind() {
        #expect(Self.findings(in: "if busy { ProgressView() }").count == 1)
        #expect(Self.findings(in: #"ProgressView("Loading…")"#).count == 1)
        #expect(Self.findings(in: "let s = UIActivityIndicatorView(style: .medium)").count == 1)
        #expect(Self.findings(in: "let s = NSProgressIndicator(frame: .zero)").count == 1)
        #expect(Self.findings(in: "ProgressView(value: 0.4)").isEmpty)
        #expect(Self.findings(in: "ProgressView().progressViewStyle(.linear)").isEmpty)
        #expect(Self.findings(in: "// was ProgressView()").isEmpty)
    }
}
