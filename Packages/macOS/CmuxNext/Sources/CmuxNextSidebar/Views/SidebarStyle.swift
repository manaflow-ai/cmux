import AppKit
import CmuxNextDesign
import SwiftUI

/// Visual constants and motion helpers local to the sidebar.
enum SidebarStyle {
    static let horizontalInset: CGFloat = 8
    static let rowCornerRadius: CGFloat = 9
    static let groupIndent: CGFloat = 12
    static let iconBox: CGFloat = 22
    static let autoscrollZone: CGFloat = 44
    static let dragThreshold: CGFloat = 4
    static let overscan: CGFloat = 400

    static let titleFont = NSFont.systemFont(ofSize: 13, weight: .regular)
    static let titleUnreadFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let subtitleFont = NSFont.systemFont(ofSize: 11, weight: .regular)
    static let headerFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    static let groupFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    static let badgeFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)

    /// Fill for multi-selected rows that are not the active one.
    static let secondarySelectionFill = NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return NSColor(white: dark ? 1 : 0, alpha: 0.07)
    }

    /// Hairline highlight on the selection pill's top edge (glass rim).
    static let pillRim = NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return NSColor(white: dark ? 1 : 1, alpha: dark ? 0.10 : 0.55)
    }

    static let badgeFill = NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return NSColor(white: dark ? 1 : 0, alpha: dark ? 0.16 : 0.10)
    }

    static func color(_ color: SidebarColor) -> NSColor {
        switch color {
        case .gray: .systemGray
        case .red: .systemRed
        case .orange: .systemOrange
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .mint: .systemMint
        case .cyan: .systemCyan
        case .blue: .systemBlue
        case .purple: .systemPurple
        case .pink: .systemPink
        }
    }

    /// A small filled circle for color menus.
    static func swatchImage(_ color: SidebarColor?, size: CGFloat = 12) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let path = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            if let color {
                self.color(color).setFill()
                path.fill()
            } else {
                NSColor.secondaryLabelColor.setStroke()
                path.lineWidth = 1
                path.stroke()
            }
            return true
        }
    }
}

/// Spring animations that honor Reduce Motion.
enum Motion {
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Row moves, gap open/close, collapse.
    static let layout = Animation.spring(duration: 0.32, bounce: 0.12)
    /// Selection pill glide.
    static let selection = Animation.spring(duration: 0.26, bounce: 0.08)
    /// Width changes.
    static let width = Animation.spring(duration: 0.30, bounce: 0)
    /// Lift and drop settle.
    static let settle = Animation.spring(duration: 0.28, bounce: 0.18)

    /// Runs `changes` inside an animation context, or instantly with Reduce
    /// Motion. AppKit calls completion handlers on the main thread.
    static func animate(_ animation: Animation, _ changes: () -> Void, completion: (@MainActor @Sendable () -> Void)? = nil) {
        if reduceMotion {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0
                changes()
            }, completionHandler: completion.map { done in { @Sendable in MainActor.assumeIsolated { done() } } })
            return
        }
        NSAnimationContext.animate(animation, changes: changes, completion: completion)
    }
}

extension NSView {
    /// Resolves a dynamic color for this view's appearance.
    func resolvedCGColor(_ color: NSColor) -> CGColor {
        var result = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { result = color.cgColor }
        return result
    }
}
