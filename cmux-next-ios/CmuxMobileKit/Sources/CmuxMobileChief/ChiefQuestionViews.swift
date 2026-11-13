#if os(iOS)
import CmuxAgentQuestion
import CmuxMobileAgentChat
import CmuxMobileDesign
import CmuxSpinner
import SwiftUI
import UIKit

/// Under the chat header: Try Again for a failed turn, why Chief is
/// unavailable, or the Mac away, and the messages waiting to send.
struct ChiefQuestionBar: View {
    let session: ChiefSession
    /// The bar grew, shrank or went away: its UIKit host lays it out again.
    var resized: () -> Void = {}
    /// The bar starts fading out (true) or in (false) over `duration`: the
    /// host fades its backing band with it (R3-2).
    var fading: (_ out: Bool, _ duration: Double) -> Void = { _, _ in }
    /// The away-Mac bar's Ask Cloud Chief (the screen hands over the composer's text).
    var askCloudChief: () -> Void = {}

    /// What the bar shows. It outlives `session.barItem` by the fade, so
    /// the bar leaves before the conversation moves up into its room (R3-2).
    @State private var shown: ChiefBarItem?
    @State private var visible = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let fadeDuration = 0.2

    /// The fade the host's band runs with the bar: none under Reduce Motion, as the bar's own.
    static func bandFadeDuration(reduceMotion: Bool) -> Double { reduceMotion ? 0 : fadeDuration }

    var body: some View {
        VStack(spacing: 0) {
            content
            ChiefOutboxView(session: session, resized: resized)
        }
            .onAppear {
                shown = Self.displayed(session.barItem)
                visible = shown != nil
                if visible { fading(false, 0) }
            }
            .onChange(of: Self.displayed(session.barItem)) { _, item in
                if let item {
                    let appearing = shown == nil
                    shown = item
                    guard appearing else { return }
                    // Room first, then the bar fades in.
                    resized()
                    fading(false, Self.bandFadeDuration(reduceMotion: reduceMotion))
                    withAnimation(.easeOut(duration: Self.fadeDuration).unlessReduceMotion) { visible = true }
                } else if shown != nil {
                    // The bar fades out first; then the room closes.
                    fading(true, Self.bandFadeDuration(reduceMotion: reduceMotion))
                    withAnimation(.easeIn(duration: Self.fadeDuration).unlessReduceMotion) {
                        visible = false
                    } completion: {
                        shown = nil
                        resized()
                    }
                }
            }
            .onChange(of: layoutKey) { resized() }
    }

    /// What the bar draws for a state. Chief's connection state never gets a bar (Aziz
    /// 2026-11-12: "get rid of this banner in chief, dont use this UX element whatsoever"):
    /// a kept or stale conversation stays on screen as it is, the outbox says what waits
    /// ("Sends when connected") with its own Retry, and Send says "Not sent" when it can't.
    static func displayed(_ item: ChiefBarItem?) -> ChiefBarItem? {
        if case .unavailable? = item { return nil }
        return item
    }

    /// What changes the bar's height: what it shows.
    private var layoutKey: String {
        switch shown {
        case .failure(let id, _)?: id
        case .macAway(let reason)?: "away\u{0}" + reason
        case .unavailable?, nil: ""
        }
    }

    @ViewBuilder private var content: some View {
        if case .failure(_, let failure)? = shown {
            failureBar(failure)
        } else if case .macAway(let reason)? = shown {
            macAwayBar(reason: reason)
        }
    }

    /// Chief's newest turn failed: the reason in plain words and Try Again,
    /// which sends the message it was answering again.
    private func failureBar(_ failure: ChiefTurnFailure) -> some View {
        Button { session.retryFailedTurn() } label: {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.bubble.fill").font(.body).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text(failure.barTitle).font(.footnote.weight(.semibold))
                    Text("Send your last message again.").font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 4)
                Text("Try Again").font(.footnote.weight(.semibold))
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .background(Color(uiColor: .secondarySystemBackground), in: .rect(cornerRadius: 20, style: .continuous))
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .accessibilityIdentifier("chief.failure.bar")
        .accessibilityHint("Sends your last message to Chief again")
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
    }

    /// The Mac is away: Chief reads its cloud copy, so what is sent waits
    /// for the Mac. Ask Cloud Chief hands the composer's text (or the newest
    /// message) to the Cloud Chief now. It was a navigation bar button the
    /// hidden bar never showed.
    private func macAwayBar(reason: String) -> some View {
        Button { askCloudChief() } label: {
            HStack(spacing: 10) {
                Image(systemName: "icloud").font(.body).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(reason).font(.footnote.weight(.semibold)).lineLimit(2)
                    Text("Messages wait for your Mac.").font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 4)
                Text("Ask Cloud Chief").font(.footnote.weight(.semibold)).foregroundStyle(.tint)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .background(Color(uiColor: .secondarySystemBackground), in: .rect(cornerRadius: 20, style: .continuous))
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .accessibilityIdentifier("chief.askCloudChief")
        .accessibilityHint("Sends your message to Cloud Chief with this chat's recent messages")
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
    }
}
#endif
