#if DEBUG || CMUX_BENCH_HOOKS
import AppKit

/// The capture scene `home-chief-profile-computer`: capture minis have no Cloud Chief with a computer,
/// so the Computer tab shows one of its own: paid, a Cloud Chief, running, a desktop drawn here, and
/// the person in control ("You're in control", Give Back).
extension HomeChiefProfileView {
    public func debugShowFixtureComputer() {
        let name = name
        paid = { true }
        cloudChief = { true }
        let screen = Self.fixtureDesktop()
        computer.source = .init(paid: { true }, chief: { name() },
                                status: { HomeChiefComputer.Status(used: true, computer: ("capture-computer", "running")) },
                                screen: { screen })
        control = HomeChiefComputerControlSource(state: { HomeChiefComputerControlState(holder: .human) },
                                                 observe: { _ in NSObject() }, takeOver: {}, handBack: {}, send: { _ in })
    }

    /// The profile shows `tab` and, for the fixture computer, its first frame and the control bar.
    public func debugSettled(_ tab: HomeChiefProfileTab, fixtureComputer: Bool) -> Bool {
        guard window != nil, !isHiddenOrHasHiddenAncestor, selectedTab == tab else { return false }
        return !fixtureComputer || (computer.screen.image != nil && !controlBar.isHidden)
    }

    /// A 1280x800 desktop: a blue wallpaper, a light window with a title bar, and a top bar.
    private static func fixtureDesktop() -> CGImage? {
        guard let context = CGContext(data: nil, width: 1280, height: 800, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        for (gray, rect) in [(-1.0, CGRect(x: 0, y: 0, width: 1280, height: 800)), (0.96, CGRect(x: 160, y: 120, width: 960, height: 560)),
                             (0.85, CGRect(x: 160, y: 640, width: 960, height: 40)), (0.1, CGRect(x: 0, y: 752, width: 1280, height: 48))] {
            context.setFillColor(gray < 0 ? CGColor(red: 0.18, green: 0.32, blue: 0.5, alpha: 1) : CGColor(gray: gray, alpha: 1))
            context.fill(rect)
        }
        return context.makeImage()
    }
}
#endif
