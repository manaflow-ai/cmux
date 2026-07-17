import AppKit
import Bonsplit
import CMUXAgentLaunch
import Foundation
import SwiftUI

extension View {
    @ViewBuilder
    func feedZeroScrollContentMargins() -> some View {
        if #available(macOS 14.0, *) {
            contentMargins(.all, 0, for: .scrollContent)
        } else {
            self
        }
    }
}

