import AppKit
import Bonsplit
import CMUXAgentLaunch
import CmuxFoundation
import Foundation
import SwiftUI

struct WrapHStack<Content: View>: View {
    let spacing: CGFloat
    let content: () -> Content

    init(spacing: CGFloat = 4, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        FlowLayout(spacing: spacing) {
            content()
        }
    }
}

