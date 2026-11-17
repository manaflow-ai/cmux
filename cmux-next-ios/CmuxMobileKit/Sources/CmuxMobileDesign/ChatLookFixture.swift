#if DEBUG && os(iOS)
import CryptoKit
import UIKit

/// `-cmux-mobile-mac-appearance NAME`: applies a Mac's `appearance` frame as hostd would serve it,
/// for screenshots and UI tests of the chat's look with no Mac (`ChatMacLookUITests`):
/// - `default`: a Mac at its defaults (Ghostty's colors, no picture): hostd sends no `chat`;
/// - `mocha`: a dark theme the person chose;
/// - `mocha-wallpaper`: the same with a picture behind the window at a 0.45 tint;
/// - `solarized-bubbles`: a light theme with sent bubble colors picked on the Mac.
/// The picture is drawn here (no asset) and goes through the same cache as a fetched one.
extension CmuxMobileMacTheme {
    static let fixtureMocha = CmuxMobileMacAppearance.Theme(
        background: "#1e1e2e", foreground: "#cdd6f4",
        palette: ["#45475a", "#f38ba8", "#a6e3a1", "#f9e2af", "#89b4fa", "#f5c2e7", "#94e2d5", "#bac2de",
                  "#585b70", "#f38ba8", "#a6e3a1", "#f9e2af", "#89b4fa", "#f5c2e7", "#94e2d5", "#a6adc8"])
    static let fixtureSolarized = CmuxMobileMacAppearance.Theme(
        background: "#fdf6e3", foreground: "#657b83",
        palette: ["#073642", "#dc322f", "#859900", "#b58900", "#268bd2", "#d33682", "#2aa198", "#eee8d5"])
    static let fixtureGhostty = CmuxMobileMacAppearance.Theme(
        background: "#282c34", foreground: "#ffffff",
        palette: ["#1d1f21", "#cc6666", "#b5bd68", "#f0c674", "#81a2be", "#b294bb", "#8abeb7", "#c5c8c6"])

    @MainActor
    public func applyLaunchFixture(arguments: [String] = ProcessInfo.processInfo.arguments) {
        guard let index = arguments.firstIndex(of: "-cmux-mobile-mac-appearance"), index + 1 < arguments.count else { return }
        matchesMac = true
        switch arguments[index + 1] {
        case "default":
            apply(CmuxMobileMacAppearance(theme: Self.fixtureGhostty))
        case "mocha":
            apply(CmuxMobileMacAppearance(theme: Self.fixtureMocha, chat: .init(background: "#1e1e2e", foreground: "#cdd6f4")))
        case "mocha-wallpaper":
            let picture = Self.fixturePicture()
            let id = SHA256.hash(data: picture).map { String(format: "%02x", $0) }.joined()
            apply(CmuxMobileMacAppearance(
                theme: Self.fixtureMocha, wallpaper: .init(id: id, bytes: picture.count, tintOpacity: 0.45),
                chat: .init(background: "#1e1e2e", foreground: "#cdd6f4", backgroundOpacity: 0.45, wallpaper: id)),
                  chatWallpaper: picture)
        case "solarized-bubbles":
            apply(CmuxMobileMacAppearance(theme: Self.fixtureSolarized, chat: .init(
                background: "#fdf6e3", foreground: "#657b83",
                bubbles: .init(sent: "#268bd2", sentText: "#fdf6e3"))))
        default:
            break
        }
    }

    /// A phone-sized JPEG: a dusk gradient with soft hills, like a painting behind the window.
    static func fixturePicture() -> Data {
        let size = CGSize(width: 600, height: 1300)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            let colors = [UIColor(red: 0.98, green: 0.55, blue: 0.35, alpha: 1).cgColor,
                          UIColor(red: 0.55, green: 0.30, blue: 0.62, alpha: 1).cgColor,
                          UIColor(red: 0.10, green: 0.16, blue: 0.40, alpha: 1).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.5, 1]) {
                cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            }
            UIColor(red: 1, green: 0.85, blue: 0.55, alpha: 1).setFill()
            cg.fillEllipse(in: CGRect(x: 360, y: 260, width: 160, height: 160))
            for (index, color) in [UIColor(red: 0.20, green: 0.22, blue: 0.45, alpha: 1),
                                   UIColor(red: 0.12, green: 0.14, blue: 0.30, alpha: 1)].enumerated() {
                let top = 760 + CGFloat(index) * 180
                let hill = UIBezierPath()
                hill.move(to: CGPoint(x: 0, y: top))
                hill.addCurve(to: CGPoint(x: size.width, y: top - 60), controlPoint1: CGPoint(x: 180, y: top - 200),
                              controlPoint2: CGPoint(x: 420, y: top + 120))
                hill.addLine(to: CGPoint(x: size.width, y: size.height))
                hill.addLine(to: CGPoint(x: 0, y: size.height))
                hill.close()
                color.setFill()
                hill.fill()
            }
        }
        return image.jpegData(compressionQuality: 0.85) ?? Data()
    }
}
#endif
