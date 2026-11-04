import AppKit
@testable import CmuxNextHomeEngine
import Foundation
import Testing

/// The Chief's profile page and the chat's popup (cmux issue 31488). The settings popover stays as it
/// was; the computer lives on this page, behind cmux Cloud, and pops up in the chat while it is used.
@MainActor @Suite(.serialized) struct HomeChiefProfileViewTests {
    @Test func theGateAsksForThePlanFirst() {
        #expect(HomeChiefProfileView.gate(paid: false, cloudChief: true, hasComputer: true) == .paywall)
        #expect(HomeChiefProfileView.gate(paid: false, cloudChief: false, hasComputer: false) == .paywall)
        #expect(HomeChiefProfileView.gate(paid: true, cloudChief: false, hasComputer: false) == .needsCloudChief)
        #expect(HomeChiefProfileView.gate(paid: true, cloudChief: true, hasComputer: false) == .notSetUp)
        #expect(HomeChiefProfileView.gate(paid: true, cloudChief: true, hasComputer: true) == nil)
    }

    @Test func aFreePlanSeesTheUpsellAndReadsNoScreen() async {
        let rig = Rig(status: .init(used: true, computer: ("vm", "running")), paid: false)
        rig.page.computer.open()
        await until { rig.feed.statuses >= 1 }
        #expect(!rig.page.tabs.isHidden, "the feature stays visible behind the paywall")
        #expect(rig.page.shownGate == .paywall)
        #expect(!rig.page.gateBox.isHidden)
        #expect(rig.feed.screens == 0)
        var upgrades = 0
        rig.page.onUpgrade = { upgrades += 1 }
        rig.page.gateButton.performClick(nil)
        #expect(upgrades == 1)
        rig.page.computer.close()
    }

    @Test func detailsFetchesNoFramesAndComputerDoes() async {
        let rig = Rig(status: .init(used: true, computer: ("vm", "running")))
        rig.page.tabs.button(.details)?.performClick(nil)
        rig.page.computer.open()
        await until { rig.feed.statuses >= 1 }
        await settle()
        #expect(rig.feed.screens == 0, "a hidden tab fetched the screen")
        rig.page.tabs.button(.computer)?.performClick(nil)
        await until { rig.page.computer.frames >= 1 }
        #expect(rig.page.computer.caption.stringValue == "mario’s screen")
        #expect(rig.page.shownGate == nil)
        rig.page.computer.close()
    }

    @Test func thePopupShowsOnlyWhileTheChiefActsDuringATurn() async {
        let feed = Feed(status: .init(used: true, computer: ("vm", "running"), acting: true))
        let popup = Self.popup(feed)
        let window = Self.window(popup)
        defer { window.close() }
        #expect(!popup.isShowing)
        popup.follow(working: true)
        await until { popup.isShowing }
        await until { popup.section.frames >= 1 }
        popup.follow(working: false)
        #expect(!popup.isShowing)
        #expect(!popup.section.isOpen)
        let reads = feed.statuses
        await settle()
        #expect(feed.statuses == reads, "an idle chat reads nothing")
    }

    @Test func aTurnThatDoesNotUseTheComputerNeverShowsIt() async {
        let feed = Feed(status: .init(used: true, computer: ("vm", "running"), acting: false))
        let popup = Self.popup(feed)
        let window = Self.window(popup)
        defer { window.close() }
        popup.follow(working: true)
        await until { feed.statuses >= 1 }
        await settle()
        #expect(!popup.isShowing)
        #expect(feed.screens == 0)
        popup.follow(working: false)
    }

    @Test func dismissingLastsForTheTurn() async {
        let feed = Feed(status: .init(used: true, computer: ("vm", "running"), acting: true))
        let popup = Self.popup(feed)
        let window = Self.window(popup)
        defer { window.close() }
        popup.follow(working: true)
        await until { popup.isShowing }
        popup.dismissButton.performClick(nil)
        #expect(!popup.isShowing)
        popup.follow(working: false)
        popup.follow(working: true)
        await until { popup.isShowing }
        popup.follow(working: false)
    }

    /// The page's states and the popup, light and dark, from the real views, for the PR:
    /// `.build/chief-computer-gallery.png` (ignored by git), returned with `cmux-ci run --artifact`.
    @Test func drawsTheStates() async throws {
        _ = NSApplication.shared
        let image = try #require(Self.desktop())
        let asleep = HomeChiefComputer.Status(used: true, computer: ("vm", "suspended"))
        let live = HomeChiefComputer.Status(used: true, computer: ("vm", "running"), acting: true)
        let never = HomeChiefComputer.Status(used: false, computer: nil)
        var rows: [[NSBitmapImageRep]] = []
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            var row: [NSBitmapImageRep] = []
            for (status, paid, cloud) in [(asleep, true, true), (live, true, true), (never, true, true), (never, true, false), (live, false, true)] {
                let rig = Rig(status: status, paid: paid, cloud: cloud, image: image)
                rig.page.setAvatar(picture: nil, text: "m")
                rig.page.frame = NSRect(x: 0, y: 0, width: 322, height: 475)
                rig.page.computer.open()
                await until { rig.feed.statuses >= 1 }
                if status.computer?.state == "running", paid { await until { rig.page.computer.frames >= 1 } }
                row.append(try Self.render(rig.page, appearance: appearance))
                rig.page.computer.close()
            }
            let feed = Feed(status: live, image: image)
            let popup = Self.popup(feed)
            let window = Self.window(popup)
            popup.follow(working: true)
            await until { popup.section.frames >= 1 }
            popup.frame.size = popup.fittingSize
            row.append(try Self.render(popup, appearance: appearance))
            popup.follow(working: false)
            window.close()
            rows.append(row)
        }
        let width = rows.flatMap { $0 }.map(\.pixelsWide).max() ?? 0, height = rows.flatMap { $0 }.map(\.pixelsHigh).max() ?? 0
        let gap = 32, columns = rows[0].count
        let total = NSSize(width: columns * (width + gap) + gap, height: rows.count * (height + gap) + gap)
        let sheet = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(total.width), pixelsHigh: Int(total.height), bitsPerSample: 8,
                                                  samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: sheet)
        NSColor(white: 0.5, alpha: 1).setFill()
        NSRect(origin: .zero, size: total).fill()
        for (y, row) in rows.enumerated() {
            for (x, cell) in row.enumerated() {
                cell.draw(at: NSPoint(x: gap + x * (width + gap), y: Int(total.height) - gap - y * (height + gap) - cell.pixelsHigh))
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        let png = try #require(sheet.representation(using: .png, properties: [:]))
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try png.write(to: package.appendingPathComponent(".build/chief-computer-gallery.png"))
    }

    private static func render(_ view: NSView, appearance: NSAppearance.Name) throws -> NSBitmapImageRep {
        let size = view.frame.size
        let backing = NSView(frame: NSRect(origin: .zero, size: size))
        backing.wantsLayer = true
        let window = NSWindow(contentRect: backing.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = backing
        defer { window.close() }
        backing.addSubview(view)
        backing.layer?.backgroundColor = (appearance == .darkAqua ? NSColor(white: 0.07, alpha: 1) : NSColor(white: 0.97, alpha: 1)).cgColor
        backing.layoutSubtreeIfNeeded()
        backing.displayIfNeeded()
        CATransaction.flush()
        let scale = 2
        let context = try #require(CGContext(data: nil, width: Int(size.width) * scale, height: Int(size.height) * scale, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.translateBy(x: 0, y: size.height * CGFloat(scale))
        context.scaleBy(x: CGFloat(scale), y: CGFloat(-scale))
        try #require(backing.layer).render(in: context)
        return NSBitmapImageRep(cgImage: try #require(context.makeImage()))
    }

    /// A synthetic 16:10 desktop for the running state, drawn here.
    private static func desktop() -> CGImage? {
        guard let context = CGContext(data: nil, width: 640, height: 400, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 0.2, green: 0.3, blue: 0.45, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 640, height: 400))
        context.setFillColor(CGColor(gray: 0.95, alpha: 1))
        context.fill(CGRect(x: 80, y: 60, width: 480, height: 280))
        return context.makeImage()
    }

    private static func popup(_ feed: Feed) -> HomeChiefComputerPopup {
        let popup = HomeChiefComputerPopup()
        popup.section.source = feed.source(paid: true)
        return popup
    }

    private static func window(_ view: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(view)
        return window
    }

    @MainActor final class Feed {
        var status: HomeChiefComputer.Status?
        var statuses = 0
        var screens = 0
        let image: CGImage?

        init(status: HomeChiefComputer.Status?, image: CGImage? = nil) {
            self.status = status
            self.image = image ?? CGContext(data: nil, width: 16, height: 10, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }

        func source(paid: Bool) -> HomeChiefComputerSection.Source {
            .init(paid: { paid }, chief: { "mario" }, status: { [self] in statuses += 1; return status }, screen: { [self] in screens += 1; return image })
        }
    }

    @MainActor struct Rig {
        let feed: Feed
        let page = HomeChiefProfileView()

        init(status: HomeChiefComputer.Status?, paid: Bool = true, cloud: Bool = true, image: CGImage? = nil) {
            let feed = Feed(status: status, image: image)
            self.feed = feed
            page.computer.source = feed.source(paid: paid)
            page.paid = { paid }
            page.cloudChief = { cloud }
            page.name = { "mario" }
            page.place = { "Runs in the cloud" }
        }
    }
}

@MainActor private func settle() async {
    for _ in 0..<200 { await Task.yield() }
}

@MainActor private func until(_ condition: () -> Bool) async {
    for _ in 0..<5000 where !condition() { await Task.yield() }
    #expect(condition())
}
