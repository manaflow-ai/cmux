import Foundation
import CMUXMobileCore
import CmuxAuthRuntime
import CmuxMobileSupport
import CmuxMobileTerminal
import CmuxMobileWorkspace
import StackAuth
import SwiftUI
#if os(iOS)
@preconcurrency import UIKit
#elseif os(macOS)
import AppKit
#endif

struct GlassInputPill<Content: View>: View {
    let height: CGFloat
    let alignment: Alignment
    let content: Content
    let onTap: () -> Void

    init(
        height: CGFloat,
        alignment: Alignment,
        @ViewBuilder content: () -> Content,
        onTap: @escaping () -> Void
    ) {
        self.height = height
        self.alignment = alignment
        self.content = content()
        self.onTap = onTap
    }

    var body: some View {
        HStack(spacing: 0) {
            content
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: alignment)
        .frame(height: height)
        .mobileGlassPill()
        .contentShape(Rectangle())
        .onTapGesture {
            onTap()
        }
    }
}
