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

struct RestoringSessionView: View {
    var body: some View {
        NavigationStack {
            ZStack {
                GameOfLifeHeader()
                    .ignoresSafeArea()

                VStack(spacing: 14) {
                    Image("CmuxLogo")
                        .resizable()
                        .renderingMode(.original)
                        .scaledToFit()
                        .frame(width: 30, height: 30)
                        .accessibilityHidden(true)

                    ProgressView(L10n.string("mobile.signIn.restoring", defaultValue: "Restoring session"))
                        .controlSize(.regular)
                }
                .font(.headline)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("MobileRestoringSessionView")
            }
            .mobileInlineNavigationTitle()
        }
    }
}
