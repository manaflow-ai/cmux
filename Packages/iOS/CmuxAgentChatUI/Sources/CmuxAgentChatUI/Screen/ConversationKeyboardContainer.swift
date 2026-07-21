import SwiftUI

/// Public façade for the single-owner transcript/composer keyboard geometry.
public struct ConversationKeyboardContainer<Transcript: View, Composer: View>: View {
    private let transcript: Transcript
    private let composer: Composer
    private let showsComposer: Bool

    public init(
        showsComposer: Bool = true,
        @ViewBuilder transcript: () -> Transcript,
        @ViewBuilder composer: () -> Composer
    ) {
        self.transcript = transcript()
        self.composer = composer()
        self.showsComposer = showsComposer
    }

    public var body: some View {
        #if os(iOS)
        ChatKeyboardTrackingContainer(
            transcript: transcript,
            composer: composer,
            showsComposer: showsComposer
        )
        #else
        VStack(spacing: 0) {
            transcript
            if showsComposer {
                composer
            }
        }
        #endif
    }
}
