import AppKit
import CmuxNextDevices

/// Your Devices row parts. Each device draws its platform's glyph here and in the palette: a Linux desktop or a Windows PC draws its
/// own glyph, not another Mac's (Leo 2026-11-16: "i dont see windows nor linux").
extension MacScreenHomeSnapshot.Device {
    /// The SF Symbol its row draws (a record from before platforms is a Mac, or a phone when `isPhone`).
    var glyph: String { MacScreenHomeView.glyph(platform ?? (isPhone ? .ios : .macos)) }

    /// This Mac can open its screen: a Mac or a Linux desktop (``DevicePlatform/hostsScreenThisMacViews``).
    var viewable: Bool { (platform ?? .macos).hostsScreenThisMacViews }
}

extension MacScreenHomeView {
    /// The SF Symbol for a device's platform, from the hub's platform (never made up).
    nonisolated static func glyph(_ platform: DevicePlatform) -> String {
        switch platform {
        case .ios: "iphone"
        case .linux: "server.rack"
        case .windows: "pc"
        case .macos: "desktopcomputer"
        }
    }

    /// The one word an online device whose screen this Mac cannot open yet (a Windows PC) shows, no buttons.
    func notViewableWord(_ device: MacScreenHomeSnapshot.Device) -> NSView {
        let word = MacScreenText(L.t("macScreen.home.notViewable", "Can’t view yet"), font: MacScreenType.caption, ink: \.secondary)
        word.setContentCompressionResistancePriority(.required, for: .horizontal)
        word.setAccessibilityIdentifier("macScreen.home.notViewable.\(device.name)")
        return word
    }

    /// The hairline between two Your Devices rows, inset to the names.
    func rowSeparator() -> NSView {
        let line = MacScreenFill(\.separator)
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        let inset = NSView()
        inset.translatesAutoresizingMaskIntoConstraints = false
        inset.addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: inset.leadingAnchor, constant: 50),
            line.trailingAnchor.constraint(equalTo: inset.trailingAnchor),
            line.topAnchor.constraint(equalTo: inset.topAnchor),
            line.bottomAnchor.constraint(equalTo: inset.bottomAnchor),
        ])
        return inset
    }
}
