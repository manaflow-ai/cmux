import AppKit
@testable import CmuxNextDesign
import Testing

/// A disabled dialog button still shows its title (the Add Server card's Approve while no server is found, Add
/// Machine's Adding… while it runs): it dims as a whole, and AppKit never repaints the title in the system's
/// disabled ink, which on the button's own fill read as no title at all (lawrence-2 shots, 2026-11-17).
@MainActor
struct CmuxDialogDisabledButtonTitleTests {
    @Test(arguments: [NSAppearance.Name.darkAqua, .aqua], [CmuxDialogButton.Role.default, .cancel])
    func aDisabledButtonDrawsItsTitleInItsOwnInk(_ appearance: NSAppearance.Name, _ role: CmuxDialogButton.Role) throws {
        let enabled = try Self.render(CmuxDialogButton(id: "approve", title: "Approve", role: role), appearance)
        let disabled = try Self.render(CmuxDialogButton(id: "approve", title: "Approve", role: role, isEnabled: false), appearance)
        #expect(enabled.inked > 40, "the title draws")
        var changed = 0
        for (lhs, rhs) in zip(enabled.pixels, disabled.pixels) where zip(lhs, rhs).contains(where: { abs(Int($0) - Int($1)) > 48 }) {
            changed += 1
        }
        #expect(changed * 10 < enabled.inked, "\(appearance.rawValue) \(role): \(changed) of \(enabled.inked) title pixels changed ink when disabled")
    }

    private static func render(_ button: CmuxDialogButton, _ appearance: NSAppearance.Name) throws -> (pixels: [[UInt8]], inked: Int) {
        let view = CmuxDialogButtonView(button, hint: nil, target: nil, action: #selector(NSObject.description))
        view.appearance = NSAppearance(named: appearance)
        view.frame = NSRect(x: 0, y: 0, width: 140, height: 26)
        view.alphaValue = 1
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        func pixel(_ x: Int, _ y: Int) -> [Int] {
            var value = [Int](repeating: 0, count: 4)
            rep.getPixel(&value, atX: x, y: y)
            return value
        }
        // The button's own fill (or nothing) at its leading edge, mid height: what is not the title.
        let ground = pixel(4, rep.pixelsHigh / 2)
        var pixels: [[UInt8]] = []
        var inked = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                let value = pixel(x, y)
                pixels.append(value.map { UInt8(clamping: $0) })
                if zip(value, ground).contains(where: { abs($0 - $1) > 48 }) { inked += 1 }
            }
        }
        return (pixels, inked)
    }
}
