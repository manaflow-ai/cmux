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
        // The host's own read of the Chief (a profile refresh) finds no Cloud computer here: it keeps this one.
        pinsControl = true
        control = HomeChiefComputerControlSource(state: { HomeChiefComputerControlState(holder: .human) },
                                                 observe: { _ in NSObject() }, takeOver: {}, handBack: {}, send: { _ in })
    }

    /// The profile shows `tab` and, for the fixture computer, its first frame and the control bar.
    public func debugSettled(_ tab: HomeChiefProfileTab, fixtureComputer: Bool) -> Bool {
        guard window != nil, !isHiddenOrHasHiddenAncestor, selectedTab == tab else { return false }
        return !fixtureComputer || (computer.screen.image != nil && !controlBar.isHidden)
    }

    /// A 1280x800 desktop, drawn top-down: a wallpaper, a light menu bar, a browser window with a
    /// page of content blocks, and the pointer over it.
    private static func fixtureDesktop() -> CGImage? {
        let space = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: 1280, height: 800, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.translateBy(x: 0, y: 800)
        context.scaleBy(x: 1, y: -1)
        func fill(_ rect: CGRect, _ r: CGFloat, _ g: CGFloat, _ b: CGFloat, radius: CGFloat = 0) {
            context.setFillColor(CGColor(red: r, green: g, blue: b, alpha: 1))
            context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.fillPath()
        }
        let wallpaper = [CGColor(red: 0.29, green: 0.45, blue: 0.68, alpha: 1), CGColor(red: 0.55, green: 0.42, blue: 0.62, alpha: 1)]
        if let gradient = CGGradient(colorsSpace: space, colors: wallpaper as CFArray, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 1280, y: 800), options: [])
        }
        // The menu bar: the wallpaper through a light veil, so the card's top edge shows on a light pane too.
        context.setFillColor(CGColor(gray: 1, alpha: 0.3))
        context.fill(CGRect(x: 0, y: 0, width: 1280, height: 28))
        for x in [24.0, 72, 128, 176] { fill(CGRect(x: x, y: 9, width: 36, height: 10), 0.97, 0.97, 0.98, radius: 5) }
        fill(CGRect(x: 1160, y: 9, width: 96, height: 10), 0.97, 0.97, 0.98, radius: 5)
        let window = CGRect(x: 150, y: 80, width: 980, height: 640)
        fill(window.insetBy(dx: -2, dy: -2), 0.2, 0.22, 0.28, radius: 18)  // its edge
        fill(window, 0.98, 0.98, 0.98, radius: 16)
        fill(CGRect(x: window.minX, y: window.minY, width: window.width, height: 56), 0.91, 0.91, 0.92, radius: 16)
        fill(CGRect(x: window.minX, y: window.minY + 40, width: window.width, height: 16), 0.91, 0.91, 0.92)
        for (index, color) in [(1.0, 0.37, 0.34), (1.0, 0.74, 0.18), (0.16, 0.79, 0.25)].enumerated() {
            fill(CGRect(x: window.minX + 22 + CGFloat(index) * 24, y: window.minY + 21, width: 14, height: 14), color.0, color.1, color.2, radius: 7)
        }
        fill(CGRect(x: window.minX + 240, y: window.minY + 14, width: 500, height: 28), 1, 1, 1, radius: 8)  // the address bar
        fill(CGRect(x: window.minX + 260, y: window.minY + 24, width: 200, height: 8), 0.7, 0.7, 0.72, radius: 4)
        let page = window.minX + 60
        fill(CGRect(x: page, y: window.minY + 100, width: 420, height: 26), 0.2, 0.2, 0.24, radius: 6)  // a heading
        for (row, width) in [(0, 760.0), (1, 700), (2, 730)] {
            fill(CGRect(x: page, y: window.minY + 150 + CGFloat(row) * 26, width: width, height: 10), 0.75, 0.75, 0.78, radius: 5)
        }
        for column in 0..<3 {
            let card = CGRect(x: page + CGFloat(column) * 290, y: window.minY + 250, width: 260, height: 300)
            fill(card, 0.93, 0.94, 0.96, radius: 12)
            let tint = [(0.42, 0.62, 0.9), (0.93, 0.6, 0.45), (0.5, 0.78, 0.6)][column]
            fill(CGRect(x: card.minX, y: card.minY, width: card.width, height: 170), tint.0, tint.1, tint.2, radius: 12)
            fill(CGRect(x: card.minX + 16, y: card.minY + 196, width: 180, height: 12), 0.3, 0.3, 0.34, radius: 6)
            fill(CGRect(x: card.minX + 16, y: card.minY + 222, width: 220, height: 9), 0.72, 0.72, 0.75, radius: 4)
            fill(CGRect(x: card.minX + 16, y: card.minY + 244, width: 150, height: 9), 0.72, 0.72, 0.75, radius: 4)
        }
        // The pointer, black with a white edge, over the middle card.
        let tip = CGPoint(x: 700, y: 400), scale: CGFloat = 1.8
        let arrow = CGMutablePath()
        let outline: [(CGFloat, CGFloat)] = [(0, 0), (0, 46), (11, 35), (19, 53), (26, 50), (18, 32), (33, 32)]
        arrow.addLines(between: outline.map {
            CGPoint(x: tip.x + $0.0 * scale, y: tip.y + $0.1 * scale)
        })
        arrow.closeSubpath()
        context.addPath(arrow)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.setStrokeColor(CGColor(gray: 1, alpha: 1))
        context.setLineWidth(5)
        context.setLineJoin(.round)
        context.drawPath(using: .fillStroke)
        return context.makeImage()
    }
}
#endif
