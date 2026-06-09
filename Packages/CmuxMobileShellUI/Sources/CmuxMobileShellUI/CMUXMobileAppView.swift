import CmuxMobileShell
import SwiftUI
#if os(iOS)
@preconcurrency import UIKit
#elseif os(macOS)
import AppKit
#endif

public struct CMUXMobileAppView: View {
    @State private var store: CMUXMobileShellStore
    #if os(iOS) && DEBUG
    /// The floating DEV dogfood pane model, built once next to the store and
    /// wired into it so the dedicated `dogfood.checklist` subscription feeds it.
    /// DEBUG-only; absent in release builds.
    @State private var dogfoodFeedbackModel: DogfoodFeedbackModel
    #endif

    public init(store: CMUXMobileShellStore = .preview()) {
        _store = State(initialValue: store)
        #if os(iOS) && DEBUG
        let model = DogfoodFeedbackModel(submitter: DogfoodFeedbackUISubmitter(store: store))
        store.setDogfoodFeedbackModel(model)
        _dogfoodFeedbackModel = State(initialValue: model)
        #endif
    }

    public var body: some View {
        CMUXMobileRootView(store: store)
            #if os(iOS) && DEBUG
            // Install the passthrough overlay window that floats the dogfood pane
            // above the terminal. The 0-size installer resolves the window scene
            // once it connects and retains the overlay window.
            .background(DogfoodPaneInstaller(model: dogfoodFeedbackModel))
            #endif
    }
}
