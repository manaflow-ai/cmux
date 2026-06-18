import CmuxAgentChat
import SwiftUI

#if canImport(UIKit)
import Accessibility
import UIKit
#endif

/// The full conversation surface: header state, transcript, typing
/// indicator, and the keyboard-attached composer.
///
/// The host creates the ``ChatConversationStore`` (with its platform event
/// source) and hands it over; this screen owns presentation state only
/// (expansion, drafts, attachments).
public struct ChatScreen: View {
    @State private var store: ChatConversationStore
    @State private var expandedIDs: Set<String> = []
    @State private var renderer = ChatMarkdownRenderer()
    @State private var contentCache = ChatContentCache()
    #if os(iOS)
    /// Transcript and composer frames in window coordinates, measured via
    /// preferences. The dismiss region is the transcript's actual visible
    /// frame, so taps over the composer/accessory bar do not dismiss the
    /// keyboard.
    @State private var transcriptFrame: CGRect = .zero
    @State private var composerFrame: CGRect = .zero
    /// The scroll-to-bottom button's frame; excluded from the dismiss region
    /// so tapping it scrolls instead of dismissing the keyboard.
    @State private var scrollButtonFrame: CGRect = .zero

    private var transcriptDismissRegion: CGRect {
        guard transcriptFrame != .zero else { return .zero }
        let bottom = composerFrame == .zero ? transcriptFrame.maxY : composerFrame.minY
        let height = max(0, bottom - transcriptFrame.minY)
        return CGRect(
            x: transcriptFrame.minX,
            y: transcriptFrame.minY,
            width: transcriptFrame.width,
            height: height
        )
    }
    #endif

    @Binding private var draft: String
    private let onOpenTerminal: () -> Void
    private let providesOwnChrome: Bool

    /// Creates the screen.
    ///
    /// - Parameters:
    ///   - store: The conversation store, constructed by the host with its
    ///     platform ``ChatEventSource``.
    ///   - onOpenTerminal: Opens the session's raw terminal surface (the
    ///     escape hatch); the host owns that navigation.
    ///   - draft: Host-owned composer draft, so a dismissed cover keeps
    ///     the half-typed prompt. Pass `.constant("")` to opt out.
    ///   - providesOwnChrome: When `true` (default, standalone use) the
    ///     screen sets its own navigation title, session-state header, and
    ///     Open-Terminal button. Pass `false` when embedded in a host that
    ///     supplies its own navigation chrome (the in-place workspace
    ///     toggle), so the two don't fight and drop the header.
    public init(
        store: ChatConversationStore,
        draft: Binding<String> = .constant(""),
        providesOwnChrome: Bool = true,
        onOpenTerminal: @escaping () -> Void
    ) {
        _store = State(initialValue: store)
        _draft = draft
        self.providesOwnChrome = providesOwnChrome
        self.onOpenTerminal = onOpenTerminal
    }

    public var body: some View {
        VStack(spacing: 0) {
            ChatTranscriptListView(
                rows: store.rows,
                expandedIDs: expandedIDs,
                agentState: store.agentState,
                hasMoreHistory: store.hasMoreHistory,
                hasLoadedInitialHistory: store.hasLoadedInitialHistory,
                initialLoadFailed: store.initialLoadFailed,
                historyTruncatedAtHead: store.historyTruncatedAtHead,
                actions: rowActions,
                onReachTop: { Task { await store.loadOlder() } },
                onRetryInitialLoad: { Task { await store.retryInitialLoad() } }
            )
            .environment(\.chatMarkdownRenderer, renderer)
            .environment(\.chatContentCache, contentCache)
            #if os(iOS)
            // Measure the transcript so the keyboard-dismiss tap fires only over
            // the conversation, never the composer/accessory bar or header.
            .chatTranscriptDismissRegion()
            #endif

            // A past/ended coding-agent session is read-only: keep the
            // transcript history but drop the text field and control
            // buttons (there is nothing live to send to). An active agent
            // gets the full interactive composer.
            if store.agentState != .ended {
                ChatComposerView(
                    agentState: store.agentState,
                    agentKind: store.descriptor.agentKind,
                    isTerminal: store.descriptor.kind == .terminal,
                    isConnected: store.isConnected,
                    draft: $draft,
                    onSend: { text, attachments in
                        Task { await store.send(text: text, attachments: attachments) }
                    },
                    onInterrupt: { hard in
                        Task { await store.interrupt(hard: hard) }
                    },
                    onOpenTerminal: onOpenTerminal
                )
                #if os(iOS)
                .reportsChatComposerFrame()
                #endif
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay(alignment: .top) {
            if let error = store.lastErrorDescription {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.red.opacity(0.92), in: .capsule)
                    .padding(.top, 4)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .accessibilityIdentifier("ChatErrorBanner")
                    .onTapGesture { store.dismissError() }
                    // Swipe the toast up to dismiss (it animates out via the
                    // move(edge: .top) transition), in addition to tap and the
                    // bounded auto-dismiss below.
                    .gesture(
                        DragGesture(minimumDistance: 8)
                            .onEnded { value in
                                if value.translation.height < -8 { store.dismissError() }
                            }
                    )
                    // Bounded auto-dismiss: the task is keyed on the error
                    // text, so a new error restarts the window, and SwiftUI
                    // cancels the sleep when the banner leaves.
                    .task(id: error) {
                        try? await Task.sleep(for: .seconds(8))
                        guard !Task.isCancelled else { return }
                        store.dismissError()
                    }
            }
        }
        .animation(.snappy(duration: 0.2), value: store.lastErrorDescription)
        .animation(.snappy(duration: 0.22), value: store.agentState == .ended)
        .modifier(ChatScreenChrome(
            store: store,
            providesOwnChrome: providesOwnChrome,
            onOpenTerminal: onOpenTerminal
        ))
        #if os(iOS)
        .onPreferenceChange(ChatTranscriptFramePreferenceKey.self) { frame in
            transcriptFrame = frame
        }
        .onPreferenceChange(ChatComposerFramePreferenceKey.self) { frame in
            composerFrame = frame
        }
        .onPreferenceChange(ChatScrollButtonFramePreferenceKey.self) { frame in
            scrollButtonFrame = frame
        }
        .dismissesKeyboardOnTap(in: transcriptDismissRegion, excluding: scrollButtonFrame)
        #endif
        .task { await store.run() }
        #if canImport(UIKit)
        .onChange(of: store.rows.last?.id) { announceLatestAgentProse() }
        .onChange(of: store.lastErrorDescription) { announceLastError() }
        #endif
    }

    #if canImport(UIKit)
    /// Speaks newly arrived agent prose so VoiceOver users hear replies
    /// without re-scanning the transcript.
    private func announceLatestAgentProse() {
        guard UIAccessibility.isVoiceOverRunning,
              case .message(let snapshot)? = store.rows.last,
              snapshot.message.role == .agent,
              case .prose(let prose) = snapshot.message.kind
        else { return }
        AccessibilityNotification.Announcement(prose.text).post()
    }

    /// Speaks the error banner's text when an error surfaces.
    private func announceLastError() {
        guard UIAccessibility.isVoiceOverRunning,
              let error = store.lastErrorDescription
        else { return }
        AccessibilityNotification.Announcement(error).post()
    }
    #endif

    private var rowActions: ChatRowActions {
        ChatRowActions(
            toggleExpanded: { id in
                if expandedIDs.contains(id) {
                    expandedIDs.remove(id)
                } else {
                    expandedIDs.insert(id)
                }
            },
            answerOption: { index in
                Task { await store.answer(optionIndex: index) }
            },
            retryPending: { id in
                Task { await store.retry(pendingID: id) }
            },
            discardPending: { id in
                store.discard(pendingID: id)
            },
            openTerminal: onOpenTerminal
        )
    }
}

/// Standalone navigation chrome for ``ChatScreen``: title, session-state
/// header, and the Open-Terminal button. Suppressed when the host supplies
/// its own chrome (the in-place workspace toggle), so a nested second
/// toolbar can't drop the header.
private struct ChatScreenChrome: ViewModifier {
    let store: ChatConversationStore
    let providesOwnChrome: Bool
    let onOpenTerminal: () -> Void

    func body(content: Content) -> some View {
        #if os(iOS)
        if providesOwnChrome {
            content
                .navigationTitle(store.descriptor.title ?? store.descriptor.agentKind.displayName)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        ChatSessionHeaderView(
                            descriptor: store.descriptor,
                            agentState: store.agentState,
                            isConnected: store.isConnected
                        )
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(action: onOpenTerminal) {
                            Image(systemName: "terminal")
                        }
                        .accessibilityLabel(
                            String(
                                localized: "chat.open_terminal.accessibility",
                                defaultValue: "Open terminal",
                                bundle: .module
                            )
                        )
                    }
                }
        } else {
            content
        }
        #else
        content
        #endif
    }
}
