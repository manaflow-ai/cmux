#if os(iOS) && DEBUG
import UIKit

/// DEBUG only, `-CmuxMobileColdFrameDemo` (with mock data): every mock terminal tab never
/// attaches and starts on a cached frame taken with the keyboard up, as Leo's was (2026-11-24:
/// "the served cached thing included the gap induced by my built-in keyboard"): the whole
/// page, its rows ending a little under mid screen, the terminal's background below them.
/// PaneLayersUITests checks the page lays it out for the keyboard as it is now.
public enum TerminalColdFrameDemo {
    public static let flag = "-CmuxMobileColdFrameDemo"
    public static var isRequested: Bool { CommandLine.arguments.contains(flag) }
    /// `-CmuxMobileColdFrameDemoSkeleton` with it: the tab never attaches and has no cached
    /// frame, so the page shows its skeleton (gallery).
    public static var servesFrame: Bool { isRequested && !CommandLine.arguments.contains("-CmuxMobileColdFrameDemoSkeleton") }

    /// Where the still's rows end, as a fraction of its height (the keyboard's top, then).
    public static let rowsEnd: CGFloat = 0.45

    @MainActor
    public static func frame() -> UIImage {
        let bounds = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen.bounds }.first
            ?? UIScreen.main.bounds
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        return UIGraphicsImageRenderer(size: bounds.size, format: format).image { context in
            UIColor.black.setFill()
            context.fill(bounds)
            let font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.white]
            let lines = [
                "~/Development/cmux $ git status",
                "On branch feat-cmux-next",
                "Changes not staged for commit:",
                "  modified:   cmux-next-ios/TerminalTabPage.swift",
                "  modified:   cmux-next-ios/PaneLayer.swift",
                "~/Development/cmux $ swift test --filter Frame",
                "Test Suite 'TerminalFrameRowsTests' passed",
                "  Executed 6 tests, with 0 failures in 0.031 s",
                "~/Development/cmux $ ls",
                "Packages  cmux-next-ios  cmux-tui  docs  scripts",
                "~/Development/cmux $ ",
            ]
            let pitch = ceil(font.lineHeight) + 2
            let bottom = bounds.height * rowsEnd
            var y = bottom - CGFloat(lines.count) * pitch
            for line in lines {
                (line as NSString).draw(at: CGPoint(x: 12, y: y), withAttributes: attributes)
                y += pitch
            }
        }
    }
}
#endif
