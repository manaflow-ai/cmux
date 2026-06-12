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
    @Binding private var draft: String
    private let onOpenTerminal: () -> Void

    /// Creates the screen.
    ///
    /// - Parameters:
    ///   - store: The conversation store, constructed by the host with its
    ///     platform ``ChatEventSource``.
    ///   - onOpenTerminal: Opens the session's raw terminal surface (the
    ///     escape hatch); the host owns that navigation.
    ///   - draft: Host-owned composer draft, so a dismissed cover keeps
    ///     the half-typed prompt. Pass `.constant("")` to opt out.
    public init(
        store: ChatConversationStore,
        draft: Binding<String> = .constant(""),
        onOpenTerminal: @escaping () -> Void
    ) {
        _store = State(initialValue: store)
        _draft = draft
        self.onOpenTerminal = onOpenTerminal
    }

    public var body: some View {
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
            }
        }
        .animation(.snappy(duration: 0.2), value: store.lastErrorDescription)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ChatComposerView(
                agentState: store.agentState,
                agentKind: store.descriptor.agentKind,
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
        }
        .navigationTitle(store.descriptor.title ?? store.descriptor.agentKind.displayName)
        #if os(iOS)
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
