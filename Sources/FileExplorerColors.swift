import AppKit
import SwiftUI

struct FileExplorerColors {
    let colorScheme: ColorScheme

    var secondaryTextColor: NSColor {
        colorScheme == .dark ? .labelColor.withAlphaComponent(0.76) : .secondaryLabelColor
    }

    var secondaryIconTint: NSColor {
        colorScheme == .dark ? .labelColor.withAlphaComponent(0.68) : .secondaryLabelColor
    }

    func gitUntrackedTextColor(lightFallback: NSColor) -> NSColor {
        colorScheme == .dark ? .labelColor.withAlphaComponent(0.84) : lightFallback
    }
}
