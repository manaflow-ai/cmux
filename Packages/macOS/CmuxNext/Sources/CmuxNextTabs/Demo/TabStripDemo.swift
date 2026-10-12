public import AppKit
public import CmuxNextDesign

/// Mock data and a standalone window for demoing the strip without the daemon.
public struct TabStripDemo {
    public init() {}
    private static var counter = 0

    public static func makeTab(title: String? = nil) -> TabItem {
        counter += 1
        let samples: [(String, String, String)] = [
            ("zsh", "~/fun/cmux", "terminal"),
            ("claude", "~/fun/cmux/Packages", "sparkles"),
            ("npm run dev", "~/fun/cmux/web", "shippingbox"),
            ("vim TabStripView.swift", "~/fun/cmux/Packages/macOS/CmuxNext", "doc.text"),
            ("cmux.com", "https://cmux.com", "globe"),
            ("htop", "~", "gauge.with.dots.needle.33percent"),
            ("git log", "~/fun/cmux", "arrow.triangle.branch"),
        ]
        let sample = samples[counter % samples.count]
        return TabItem(
            id: TabID("demo-\(counter)"),
            title: title ?? sample.0,
            subtitle: sample.1,
            icon: .symbol(sample.2)
        )
    }

    private static var groupCounter = 0

    /// A new demo group with the next group color.
    public static func makeGroup(name: String = "") -> TabGroupItem {
        groupCounter += 1
        let color = GroupColor.allCases[groupCounter % GroupColor.allCases.count]
        return TabGroupItem(id: TabGroupID("demo-group-\(groupCounter)"), name: name, colorToken: color)
    }

    /// A model with a few tabs (one pinned, one busy, one unread), a named
    /// group, and a collapsed unnamed group.
    public static func makeModel(style: TabStripStyle = .chrome) -> TabStripModel {
        var tabs = (0..<9).map { _ in makeTab() }
        tabs[0].isPinned = true
        tabs[0].icon = .symbol("pin.fill")
        tabs[2].isBusy = true
        tabs[3].isUnread = true
        tabs[4].status = .needsInput
        var named = makeGroup(name: "cmux")
        named.colorToken = .green
        var unnamed = makeGroup()
        unnamed.colorToken = .purple
        unnamed.isCollapsed = true
        for index in [2, 3, 4] { tabs[index].groupID = named.id }
        for index in [6, 7] { tabs[index].groupID = unnamed.id }
        let model = TabStripModel(tabs: tabs, groups: [named, unnamed], selectedID: tabs[1].id, style: style)
        model.intentHandler = { [weak model] intent in
            model?.apply(intent) { makeTab() }
        }
        return model
    }

    /// A window with two strips (drag tabs between them) and demo controls.
    public static func makeWindow() -> NSWindow {
        let controller = DemoContentView()
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 960, height: 400),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = Strings.demoWindowTitle
        window.contentView = controller
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}

/// Draws fake terminal thumbnails.
public final class MockTabPreviewProvider: TabPreviewProvider {
    public init() {}

    public func previewImage(for tab: TabID, maxPixelSize: CGSize) async -> CGImage? {
        let width = Int(maxPixelSize.width)
        let height = Int(maxPixelSize.height)
        guard width > 0, height > 0, let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(gray: 0.08, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        var seed = UInt64(abs(tab.rawValue.hashValue))
        let line = CGFloat(height) / 14
        for row in 0..<12 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let length = CGFloat(seed % 70 + 20) / 100 * CGFloat(width - 24)
            let gray = row == 0 ? 0.85 : 0.35 + CGFloat(seed % 40) / 100
            context.setFillColor(CGColor(gray: gray, alpha: 1))
            let y = CGFloat(height) - CGFloat(row + 1) * line - 6
            context.fill(CGRect(x: 12, y: y, width: length, height: line * 0.45))
        }
        return context.makeImage()
    }
}
