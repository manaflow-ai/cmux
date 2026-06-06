import CmuxMobileShell
import SwiftUI
#if os(iOS)
import CmuxMobileFeedback
@preconcurrency import UIKit
#elseif os(macOS)
import AppKit
#endif

public struct CMUXMobileAppView: View {
    @State private var store: CMUXMobileShellStore
    #if os(iOS)
    private let feedbackClient: any MobileFeedbackSubmitting
    #endif

    #if os(iOS)
    public init(
        store: CMUXMobileShellStore = .preview(),
        feedbackClient: any MobileFeedbackSubmitting = MobileFeedbackClient()
    ) {
        _store = State(initialValue: store)
        self.feedbackClient = feedbackClient
    }
    #else
    public init(store: CMUXMobileShellStore = .preview()) {
        _store = State(initialValue: store)
    }
    #endif

    public var body: some View {
        #if os(iOS)
        CMUXMobileRootView(store: store, feedbackClient: feedbackClient)
        #else
        CMUXMobileRootView(store: store)
        #endif
    }
}
