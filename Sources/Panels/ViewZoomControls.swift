import AppKit
import Foundation

enum ViewZoomCommand: Equatable {
    case zoomIn
    case zoomOut
    case reset
}

enum ViewZoomControl {
    static let defaultFactor: CGFloat = 1.0
    static let step: CGFloat = 0.10
    static let minimumFactor: CGFloat = 0.50
    static let maximumFactor: CGFloat = 3.00

    static func normalized(_ factor: CGFloat) -> CGFloat {
        guard factor.isFinite else { return defaultFactor }
        return min(max(factor, minimumFactor), maximumFactor)
    }

    static func applying(_ command: ViewZoomCommand, to factor: CGFloat) -> CGFloat {
        switch command {
        case .zoomIn:
            return normalized(factor + step)
        case .zoomOut:
            return normalized(factor - step)
        case .reset:
            return defaultFactor
        }
    }

    static func percentText(for factor: CGFloat) -> String {
        "\(Int((normalized(factor) * 100).rounded()))%"
    }

    static func textEditorFontSize(for factor: CGFloat) -> CGFloat {
        normalized(factor) * textEditorDefaultFontSize
    }

    static func textEditorZoomFactor(forFontSize fontSize: CGFloat) -> CGFloat {
        normalized(fontSize / textEditorDefaultFontSize)
    }

    static func command(for event: NSEvent) -> ViewZoomCommand? {
        if KeyboardShortcutSettings.shortcut(for: .browserZoomIn).matches(event: event) {
            return .zoomIn
        }
        if KeyboardShortcutSettings.shortcut(for: .browserZoomOut).matches(event: event) {
            return .zoomOut
        }
        if KeyboardShortcutSettings.shortcut(for: .browserZoomReset).matches(event: event) {
            return .reset
        }

        let defaultAction = browserZoomShortcutAction(
            flags: event.modifierFlags,
            chars: event.charactersIgnoringModifiers ?? "",
            keyCode: event.keyCode,
            literalChars: event.characters
        )

        switch defaultAction {
        case .zoomIn where KeyboardShortcutSettings.shortcut(for: .browserZoomIn) == KeyboardShortcutSettings.Action.browserZoomIn.defaultShortcut:
            return .zoomIn
        case .zoomOut where KeyboardShortcutSettings.shortcut(for: .browserZoomOut) == KeyboardShortcutSettings.Action.browserZoomOut.defaultShortcut:
            return .zoomOut
        case .reset where KeyboardShortcutSettings.shortcut(for: .browserZoomReset) == KeyboardShortcutSettings.Action.browserZoomReset.defaultShortcut:
            return .reset
        default:
            return nil
        }
    }

    static let textEditorDefaultFontSize: CGFloat = 13
}

@MainActor
protocol ViewZoomControlling: AnyObject {
    var viewZoomFactor: CGFloat { get }

    @discardableResult
    func setViewZoomFactor(_ factor: CGFloat) -> Bool

    @discardableResult
    func performViewZoomCommand(_ command: ViewZoomCommand) -> Bool
}

extension ViewZoomControlling {
    @discardableResult
    func performViewZoomCommand(_ command: ViewZoomCommand) -> Bool {
        setViewZoomFactor(ViewZoomControl.applying(command, to: viewZoomFactor))
    }
}
