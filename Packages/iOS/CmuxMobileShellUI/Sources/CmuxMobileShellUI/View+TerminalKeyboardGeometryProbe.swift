#if os(iOS)
import CmuxMobileDiagnostics
import SwiftUI

/// DEBUG bisect probe for keyboard-coupled hosting geometry: logs the labeled
/// node's height and bottom safe-area inset whenever either changes, so a
/// `kb.swiftui` trace shows exactly which span of the terminal's modifier
/// stack absorbs or re-introduces a bottom inset across keyboard toggles.
/// Compiles to a no-op outside DEBUG.
private struct TerminalKeyboardGeometryProbe: ViewModifier {
    let label: String

    func body(content: Content) -> some View {
        #if DEBUG
        content.background {
            GeometryReader { proxy in
                let signature = "h=\(Int(proxy.size.height)) sabB=\(Int(proxy.safeAreaInsets.bottom))"
                Color.clear
                    .onChange(of: signature, initial: true) { _, value in
                        MobileDebugLog.anchormux("kb.swiftui \(label) \(value)")
                    }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        #else
        content
        #endif
    }
}

extension View {
    /// Logs `kb.swiftui <label> h=… sabB=…` on every geometry change (DEBUG).
    func terminalKeyboardGeometryProbe(_ label: String) -> some View {
        modifier(TerminalKeyboardGeometryProbe(label: label))
    }
}
#endif
