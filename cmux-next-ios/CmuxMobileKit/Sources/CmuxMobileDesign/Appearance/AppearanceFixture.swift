#if os(iOS) && DEBUG
import Foundation
import UIKit

/// DEBUG: a Mac's appearance without a Mac, for screenshots and UI tests.
/// `CMUX_MOBILE_APPEARANCE_FIXTURE=catppuccin` (or the launch argument
/// `-cmux-mobile-appearance-fixture catppuccin`) stores the fixture as the
/// snapshot of the Mac `fixture-mac` before the launch load, as
/// `AppearanceSync` would after a `get-appearance`:
///
/// - `catppuccin`: Catppuccin Mocha (dark) and Latte (light), magenta accent,
///   two-tone window, a background picture (drawn here, 1600 x 1000) at 0.9
///   opacity with a 12 pt blur, glass transparency 0.35, bubble colors.
/// - `nord`: Nord for both schemes (`follows_system: false`, so the phone
///   holds dark), blue accent, no background.
/// - `none`: nothing stored (the neutral look).
public struct CmuxMobileAppearanceFixture: Sendable {
    public static let macID = "fixture-mac"
    public let name: String

    public static func requested(environment: [String: String] = ProcessInfo.processInfo.environment,
                                 arguments: [String] = ProcessInfo.processInfo.arguments) -> CmuxMobileAppearanceFixture? {
        if let value = environment["CMUX_MOBILE_APPEARANCE_FIXTURE"], !value.isEmpty { return .init(name: value) }
        if let index = arguments.firstIndex(of: "-cmux-mobile-appearance-fixture"), index + 1 < arguments.count {
            return .init(name: arguments[index + 1])
        }
        return nil
    }

    /// Stores the fixture's snapshot and picture (or, for `none`, forgets the matched Mac).
    public func install(into disk: CmuxMobileAppearanceDisk) {
        guard var snapshot = Self.snapshot(named: name) else {
            disk.lastMacID = nil
            return
        }
        if snapshot.background != nil, let data = Self.picture() {
            let sha = CmuxMobileAppearanceDisk.sha256(data)
            disk.storeAsset(data, sha256: sha, bytes: data.count)
            snapshot.background = .init(sha256: sha, bytes: data.count, width: 1600, height: 1000, luminance: 0.42, opacity: 0.9, blur: 12)
        }
        disk.store(snapshot, macID: Self.macID)
    }

    public static func snapshot(named name: String) -> CmuxMobileAppearanceSnapshot? {
        switch name {
        case "catppuccin":
            return CmuxMobileAppearanceSnapshot(
                revision: 7,
                theme: .init(dark: .init(name: "Catppuccin Mocha", input: mocha), light: .init(name: "Catppuccin Latte", input: latte), followsSystem: true),
                accent: "magenta", chromeStyle: "two-tone", hue: 0.5, saturation: 1, glassTransparency: 0.35, sidebarSurface: "separate",
                terminal: .init(fontFamily: "Menlo", fontSize: 13),
                chat: .init(sent: "#CBA6F7", sentText: "#1E1E2E"),
                groups: .init(palette: "theme", gradient: "aurora"),
                background: .init(sha256: String(repeating: "0", count: 64), bytes: 0, width: 1600, height: 1000))
        case "nord":
            return CmuxMobileAppearanceSnapshot(
                revision: 3,
                theme: .init(dark: .init(name: "Nord", input: nord), light: .init(name: "Nord", input: nord), followsSystem: false),
                accent: "blue", chromeStyle: "default", glassTransparency: 0, sidebarSurface: "same",
                terminal: .init(fontFamily: "JetBrains Mono", fontSize: 13),
                groups: .init(palette: "vibrant"))
        default:
            return nil
        }
    }

    public static let mocha = CmuxMobileAppearanceSnapshot.Input(
        background: "#1E1E2E", foreground: "#CDD6F4",
        palette: ["#45475A", "#F38BA8", "#A6E3A1", "#F9E2AF", "#89B4FA", "#F5C2E7", "#94E2D5", "#BAC2DE",
                  "#585B70", "#F38BA8", "#A6E3A1", "#F9E2AF", "#89B4FA", "#F5C2E7", "#94E2D5", "#A6ADC8"],
        selectionBackground: "#585B70", cursor: "#F5E0DC", backgroundOpacity: 0.92)
    public static let latte = CmuxMobileAppearanceSnapshot.Input(
        background: "#EFF1F5", foreground: "#4C4F69",
        palette: ["#5C5F77", "#D20F39", "#40A02B", "#DF8E1D", "#1E66F5", "#EA76CB", "#179299", "#ACB0BE",
                  "#6C6F85", "#D20F39", "#40A02B", "#DF8E1D", "#1E66F5", "#EA76CB", "#179299", "#BCC0CC"],
        selectionBackground: "#ACB0BE", cursor: "#DC8A78", backgroundOpacity: 0.92)
    public static let nord = CmuxMobileAppearanceSnapshot.Input(
        background: "#2E3440", foreground: "#D8DEE9",
        palette: ["#3B4252", "#BF616A", "#A3BE8C", "#EBCB8B", "#81A1C1", "#B48EAD", "#88C0D0", "#E5E9F0",
                  "#4C566A", "#BF616A", "#A3BE8C", "#EBCB8B", "#81A1C1", "#B48EAD", "#8FBCBB", "#ECEFF4"],
        cursor: "#ECEFF4")

    /// A landscape picture (dusk over hills), drawn here so the fixture ships
    /// no image: JPEG at quality 0.85, as the Mac exports its backdrop.
    public static func picture() -> Data? {
        let size = CGSize(width: 1600, height: 1000)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            let space = CGColorSpaceCreateDeviceRGB()
            let sky = [UIColor(red: 0.18, green: 0.12, blue: 0.36, alpha: 1).cgColor,
                       UIColor(red: 0.62, green: 0.27, blue: 0.55, alpha: 1).cgColor,
                       UIColor(red: 0.98, green: 0.62, blue: 0.42, alpha: 1).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: space, colors: sky, locations: [0, 0.6, 1]) {
                cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height * 0.75), options: [.drawsAfterEndLocation])
            }
            UIColor(red: 1, green: 0.86, blue: 0.62, alpha: 1).setFill()
            cg.fillEllipse(in: CGRect(x: 1020, y: 470, width: 220, height: 220))
            let hills: [(UIColor, CGFloat, CGFloat)] = [
                (UIColor(red: 0.30, green: 0.17, blue: 0.40, alpha: 1), 640, 90),
                (UIColor(red: 0.18, green: 0.11, blue: 0.29, alpha: 1), 730, 120),
                (UIColor(red: 0.09, green: 0.06, blue: 0.17, alpha: 1), 830, 70),
            ]
            for (index, (color, base, amplitude)) in hills.enumerated() {
                color.setFill()
                let path = UIBezierPath()
                path.move(to: CGPoint(x: 0, y: size.height))
                for x in stride(from: 0, through: size.width, by: 20) {
                    let phase = Double(x) / 260 + Double(index) * 1.7
                    path.addLine(to: CGPoint(x: x, y: base - amplitude * CGFloat(sin(phase) * 0.6 + sin(phase * 2.3) * 0.4)))
                }
                path.addLine(to: CGPoint(x: size.width, y: size.height))
                path.close()
                path.fill()
            }
        }
        return image.jpegData(compressionQuality: 0.85)
    }
}
#endif
