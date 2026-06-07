import CmuxMobileShell
import SwiftUI
#if os(iOS)
import CmuxMobileFeedback
@preconcurrency import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Root SwiftUI entry point for the cmux iOS app surface.
public struct CMUXMobileAppView: View {
    @State private var store: CMUXMobileShellStore
    #if os(iOS)
    private let feedbackClient: any MobileFeedbackSubmitting
    #endif

    #if os(iOS)
    /// Creates the mobile app view.
    ///
    /// - Parameters:
    ///   - store: Shell store backing the mobile UI.
    ///   - feedbackClient: Feedback submission dependency passed into the diagnostics feedback flow.
    public init(
        store: CMUXMobileShellStore = .preview(),
        feedbackClient: any MobileFeedbackSubmitting
    ) {
        _store = State(initialValue: store)
        self.feedbackClient = feedbackClient
    }
    #else
    /// Creates the mobile app view.
    ///
    /// - Parameter store: Shell store backing the mobile UI.
    public init(store: CMUXMobileShellStore = .preview()) {
        _store = State(initialValue: store)
    }
    #endif

    /// The root mobile app view content.
    public var body: some View {
        #if os(iOS)
        CMUXMobileRootView(store: store, feedbackClient: feedbackClient)
        #else
        CMUXMobileRootView(store: store)
        #endif
    }
}
