import SwiftUI

// MARK: - Backport

/// Centralized backports for newer SwiftUI APIs we want to use when available.
struct Backport<Content> {
    let content: Content
}

extension View {
    var backport: Backport<Self> {
        Backport(content: self)
    }

    @ViewBuilder
    func safeHelp(_ text: String) -> some View {
        if text.isEmpty {
            self
        } else {
            help(text)
        }
    }
}

extension Scene {
    var backport: Backport<Self> {
        Backport(content: self)
    }
}

// MARK: - BackportKeyPressResult

/// Result type for backported onKeyPress handler
enum BackportKeyPressResult {
    case handled
    case ignored
}

extension Backport where Content: View {
    func pointerStyle(_ style: BackportPointerStyle?) -> some View {
        #if canImport(AppKit)
            if #available(macOS 15, *) {
                return content.pointerStyle(style?.official)
            } else {
                return content
            }
        #else
            return content
        #endif
    }

    /// Backported onKeyPress that works on macOS 14+ and is a no-op on macOS 13.
    func onKeyPress(_ key: KeyEquivalent, action: @escaping (EventModifiers) -> BackportKeyPressResult) -> some View {
        #if canImport(AppKit)
            if #available(macOS 14, *) {
                return content.onKeyPress(key, phases: [.down, .repeat], action: { keyPress in
                    switch action(keyPress.modifiers) {
                        case .handled: .handled
                        case .ignored: .ignored
                    }
                })
            } else {
                return content
            }
        #else
            return content
        #endif
    }
}

// MARK: - BackportPointerStyle

enum BackportPointerStyle {
    case `default`
    case grabIdle
    case grabActive
    case horizontalText
    case verticalText
    case link
    case resizeLeft
    case resizeRight
    case resizeUp
    case resizeDown
    case resizeUpDown
    case resizeLeftRight

    // MARK: Computed Properties

    #if canImport(AppKit)
        @available(macOS 15, *)
        var official: PointerStyle {
            switch self {
                case .default: .default
                case .grabIdle: .grabIdle
                case .grabActive: .grabActive
                case .horizontalText: .horizontalText
                case .verticalText: .verticalText
                case .link: .link
                case .resizeLeft: .frameResize(position: .trailing, directions: [.inward])
                case .resizeRight: .frameResize(position: .leading, directions: [.inward])
                case .resizeUp: .frameResize(position: .bottom, directions: [.inward])
                case .resizeDown: .frameResize(position: .top, directions: [.inward])
                case .resizeUpDown: .frameResize(position: .top)
                case .resizeLeftRight: .frameResize(position: .trailing)
            }
        }
    #endif
}
