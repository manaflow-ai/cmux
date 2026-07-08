import AppKit
import CmuxFoundation
import Foundation
import SwiftUI

// MARK: - Explorer Visual Style

enum FileExplorerStyle: Int, CaseIterable {
    case liquidGlass = 0
    case highDensity = 1
    case terminalStealth = 2
    case proStudio = 3
    case finder = 4

    var label: String {
        switch self {
        case .liquidGlass: return "Liquid Glass"
        case .highDensity: return "High-Density IDE"
        case .terminalStealth: return "Terminal Stealth"
        case .proStudio: return "Pro Studio"
        case .finder: return "Finder"
        }
    }

    var rowHeight: CGFloat {
        let baseHeight: CGFloat
        switch self {
        case .liquidGlass: baseHeight = 28
        case .highDensity: baseHeight = 20
        case .terminalStealth: baseHeight = 24
        case .proStudio: baseHeight = 32
        case .finder: baseHeight = 26
        }
        return GlobalFontMagnification.scaledSize(baseHeight)
    }

    var indentation: CGFloat {
        switch self {
        case .liquidGlass: return 16
        case .highDensity: return 12
        case .terminalStealth: return 14
        case .proStudio: return 20
        case .finder: return 18
        }
    }

    var iconSize: CGFloat {
        switch self {
        case .liquidGlass: return 16
        case .highDensity: return 14
        case .terminalStealth: return 12
        case .proStudio: return 18
        case .finder: return 18
        }
    }

    var iconWeight: NSFont.Weight {
        switch self {
        case .liquidGlass: return .regular
        case .highDensity: return .regular
        case .terminalStealth: return .light
        case .proStudio: return .regular
        case .finder: return .medium
        }
    }

    var nameFont: NSFont {
        switch self {
        case .liquidGlass: return GlobalFontMagnification.systemFont(ofSize: 13, weight: .medium)
        case .highDensity: return GlobalFontMagnification.systemFont(ofSize: 11, weight: .regular)
        case .terminalStealth: return GlobalFontMagnification.monospacedSystemFont(ofSize: 12, weight: .regular)
        case .proStudio: return GlobalFontMagnification.systemFont(ofSize: 14, weight: .semibold)
        case .finder: return GlobalFontMagnification.systemFont(ofSize: 13, weight: .regular)
        }
    }

    var iconToTextSpacing: CGFloat {
        switch self {
        case .liquidGlass: return 8
        case .highDensity: return 4
        case .terminalStealth: return 6
        case .proStudio: return 12
        case .finder: return 6
        }
    }

    var selectionInset: CGFloat {
        switch self {
        case .liquidGlass: return 8
        case .highDensity: return 0
        case .terminalStealth: return 0
        case .proStudio: return 4
        case .finder: return 4
        }
    }

    var selectionRadius: CGFloat {
        switch self {
        case .liquidGlass: return 6
        case .highDensity: return 0
        case .terminalStealth: return 0
        case .proStudio: return 8
        case .finder: return 5
        }
    }

    var selectionColor: NSColor {
        switch self {
        case .liquidGlass: return .controlAccentColor.withAlphaComponent(0.15)
        case .highDensity: return .selectedContentBackgroundColor
        case .terminalStealth: return .controlAccentColor
        case .proStudio: return .controlAccentColor
        case .finder: return .controlAccentColor.withAlphaComponent(0.15)
        }
    }

    var hoverColor: NSColor {
        switch self {
        case .liquidGlass: return .labelColor.withAlphaComponent(0.05)
        case .highDensity: return .white.withAlphaComponent(0.05)
        case .terminalStealth: return .white.withAlphaComponent(0.03)
        case .proStudio: return .white.withAlphaComponent(0.1)
        case .finder: return .labelColor.withAlphaComponent(0.04)
        }
    }

    var usesBorderSelection: Bool {
        self == .terminalStealth
    }

    var fileIconTint: NSColor {
        switch self {
        case .liquidGlass: return .secondaryLabelColor
        case .highDensity: return .secondaryLabelColor
        case .terminalStealth: return .tertiaryLabelColor
        case .proStudio: return .secondaryLabelColor
        case .finder: return NSColor(white: 0.55, alpha: 1.0)
        }
    }

    var folderIconTint: NSColor {
        switch self {
        case .liquidGlass: return .systemBlue
        case .highDensity: return .secondaryLabelColor
        case .terminalStealth: return .tertiaryLabelColor
        case .proStudio: return .systemBlue
        case .finder: return .systemBlue
        }
    }

    func gitColor(for status: GitFileStatus) -> NSColor {
        switch self {
        case .liquidGlass:
            switch status {
            case .modified: return .systemOrange
            case .added: return .systemTeal
            case .deleted: return .systemRed
            case .renamed: return .systemPurple
            case .untracked: return .quaternaryLabelColor
            }
        case .highDensity:
            switch status {
            case .modified: return .systemYellow
            case .added: return .systemGreen
            case .deleted: return .systemRed
            case .renamed: return .systemBlue
            case .untracked: return .tertiaryLabelColor
            }
        case .terminalStealth:
            switch status {
            case .modified: return NSColor(red: 0.8, green: 0.7, blue: 0.4, alpha: 1.0)
            case .added: return NSColor(red: 0.5, green: 0.8, blue: 0.5, alpha: 1.0)
            case .deleted: return NSColor(red: 0.8, green: 0.4, blue: 0.4, alpha: 1.0)
            case .renamed: return NSColor(red: 0.5, green: 0.7, blue: 0.9, alpha: 1.0)
            case .untracked: return NSColor(white: 0.5, alpha: 1.0)
            }
        case .proStudio:
            switch status {
            case .modified: return .systemYellow
            case .added: return .systemGreen
            case .deleted: return .systemPink
            case .renamed: return .systemCyan
            case .untracked: return .systemGray
            }
        case .finder:
            switch status {
            case .modified: return .systemOrange
            case .added: return .systemGreen
            case .deleted: return .systemRed
            case .renamed: return .systemBlue
            case .untracked: return .tertiaryLabelColor
            }
        }
    }

    static var current: FileExplorerStyle {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "fileExplorer.style") == nil {
            return .highDensity
        }
        return FileExplorerStyle(rawValue: defaults.integer(forKey: "fileExplorer.style")) ?? .highDensity
    }
}
