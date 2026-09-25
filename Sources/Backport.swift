import SwiftUI

// Centralized backports for newer SwiftUI APIs we want to use when available.
struct Backport<Content> {
    let content: Content
}

extension View {
    var backport: Backport<Self> { Backport(content: self) }

    @ViewBuilder
    func safeHelp(_ text: String) -> some View {
        if text.isEmpty {
            self
        } else {
            self.help(text)
        }
    }
}

extension Scene {
    var backport: Backport<Self> { Backport(content: self) }
}

/// Result type for backported onKeyPress handler
enum BackportKeyPressResult {
    case handled
    case ignored
}

extension Backport where Content: View {
    /// Applies a cursor style on macOS 15 and falls back to an AppKit cursor
    /// update on macOS 14, where SwiftUI does not expose `pointerStyle`.
    func pointerStyle(_ style: BackportPointerStyle?) -> some View {
        content.modifier(BackportPointerStyleModifier(style: style))
    }
}

private struct BackportPointerStyleModifier: ViewModifier {
    let style: BackportPointerStyle?
    @Environment(\.isEnabled) private var isEnabled

    @ViewBuilder
    func body(content: Content) -> some View {
        let effectiveStyle = PointingHandCursorPolicy.pointerStyle(
            isEnabled: isEnabled,
            requested: style
        )
        #if canImport(AppKit)
        if #available(macOS 15, *) {
            content.pointerStyle(effectiveStyle?.official)
        } else {
            content.overlay {
                BackportCursorRectView(style: effectiveStyle)
                    .allowsHitTesting(false)
            }
        }
        #else
        content
        #endif
    }
}

#if canImport(AppKit)
private struct BackportCursorRectView: NSViewRepresentable {
    let style: BackportPointerStyle?

    func makeNSView(context: Context) -> BackportCursorRectNSView {
        BackportCursorRectNSView(style: style)
    }

    func updateNSView(_ nsView: BackportCursorRectNSView, context: Context) {
        nsView.style = style
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}

private final class BackportCursorRectNSView: NSView {
    var style: BackportPointerStyle? {
        didSet {
            guard oldValue != style else { return }
            window?.invalidateCursorRects(for: self)
        }
    }

    init(style: BackportPointerStyle?) {
        self.style = style
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        switch style {
        case .link:
            addCursorRect(bounds, cursor: .pointingHand)
        case .default:
            addCursorRect(bounds, cursor: .arrow)
        default:
            break
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
#endif

extension Backport where Content: View {
    /// Backported onKeyPress that works on macOS 14+ and is a no-op on macOS 13.
    func onKeyPress(_ key: KeyEquivalent, action: @escaping (EventModifiers) -> BackportKeyPressResult) -> some View {
        #if canImport(AppKit)
        if #available(macOS 14, *) {
            return content.onKeyPress(key, phases: [.down, .repeat], action: { keyPress in
                switch action(keyPress.modifiers) {
                case .handled: return .handled
                case .ignored: return .ignored
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

enum BackportPointerStyle: Equatable {
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

    #if canImport(AppKit)
    @available(macOS 15, *)
    var official: PointerStyle {
        switch self {
        case .default: return .default
        case .grabIdle: return .grabIdle
        case .grabActive: return .grabActive
        case .horizontalText: return .horizontalText
        case .verticalText: return .verticalText
        case .link: return .link
        case .resizeLeft: return .frameResize(position: .trailing, directions: [.inward])
        case .resizeRight: return .frameResize(position: .leading, directions: [.inward])
        case .resizeUp: return .frameResize(position: .bottom, directions: [.inward])
        case .resizeDown: return .frameResize(position: .top, directions: [.inward])
        case .resizeUpDown: return .frameResize(position: .top)
        case .resizeLeftRight: return .frameResize(position: .trailing)
        }
    }
    #endif
}
