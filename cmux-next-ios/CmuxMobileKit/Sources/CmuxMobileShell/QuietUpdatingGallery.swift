#if DEBUG && os(iOS)
import CmuxMobileDesign
import CmuxSpinner
import SwiftUI

/// Leo, 2026-11-24: "the 'updating' is a bit meh ... they dont need to know that it's updating
/// before they KNOW it's updating". The places that said "Updating…" over rows the phone already
/// had, one screen per variant (`-cmux-mobile-recovery-gallery quiet-before|quiet-a|quiet-b|quiet-c`):
/// - `before`: as the app drew them (the Workspaces and Agent Chats subtitles after 1.5 s, the
///   Home and agent chat chip after 10 s);
/// - `a` (picked): nothing while kept rows show; only a real outage or failure speaks (its chip
///   and words are unchanged, the last panel);
/// - `b`: a thin progress hairline under the bar, past the same delays;
/// - `c`: the "Updating" chip only past 8 s (drawn as shown).
struct QuietUpdatingGallery: View {
    let variant: String

    private let workspaces = ["cmux · Fix the login redirect", "api · Bump the parser to 2.4", "web · Why is CI slow on arm64?"]
    private let conversations = ["Chief · Landed the chip", "Design · Gallery for the composer", "Infra · Rotate runners"]
    private let chats = ["Refactor transport layer", "Bump the parser to 2.4", "Why is CI slow on arm64?"]

    var body: some View {
        ScrollView {
            VStack(spacing: 6) {
                Text(title).font(.footnote.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20)
                label("Workspaces · team refresh over cached rows")
                list("Workspaces", rows: workspaces, subtitle: subtitle(after: "1.5 s"))
                label("Home · kept conversations, the Mac's list not in yet")
                list("Home", rows: conversations, subtitle: "") { chip }
                label("Agent chat · kept turns, catching up with the Mac")
                chat
                label("Agent Chats · kept chats, reopen refresh")
                list("Agent Chats", rows: chats, subtitle: subtitle(after: "1.5 s"))
                if variant == "a" {
                    label("A · still said: the Mac offline past 10 s (unchanged)")
                    list("Home", rows: conversations, subtitle: "") {
                        ConnectionChip(.init(.macOffline, sentence: "Mac Studio is offline."), downSince: nil)
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .background(CmuxMobileTheme.standard.colors.bg.color)
        .accessibilityIdentifier("recoveryGallery.quiet.\(variant)")
    }

    private var title: String {
        switch variant {
        case "before": "Before · \"Updating…\" over rows the phone has"
        case "a": "A · picked · nothing while the cache shows"
        case "b": "B · a hairline under the bar, past the delay"
        default: "C · the chip only past 8 s"
        }
    }

    private func subtitle(after delay: String) -> String {
        variant == "before" ? "Updating…" : ""
    }

    private var hairline: Bool { variant == "b" }

    @ViewBuilder private var chip: some View {
        if variant == "before" || variant == "c" { UpdatingChipReplica() }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20)
    }

    private func list(_ title: String, rows: [String], subtitle: String) -> some View {
        list(title, rows: rows, subtitle: subtitle) { EmptyView() }
    }

    private func list<Overlay: View>(_ title: String, rows: [String], subtitle: String,
                                     @ViewBuilder overlay: () -> Overlay) -> some View {
        NavigationStack {
            List {
                // visible-only: a fixed gallery of three rows.
                ForEach(rows, id: \.self) { Text($0).font(.subheadline) }
            }
            .listStyle(.plain)
            .scrollDisabled(true)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .navigationSubtitle(subtitle)
            .overlay(alignment: .top) { if hairline { Hairline() } }
            .overlay(alignment: .bottom) { overlay().padding(.bottom, 8) }
        }
        .frame(height: 138)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 16)
    }

    private var chat: some View {
        let theme = CmuxMobileTheme.standard
        return VStack(alignment: .leading, spacing: 6) {
            Text("Both test suites pass on the new transport.").font(.subheadline)
                .padding(8).background(theme.colors.label2.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            Spacer(minLength: 0)
            ZStack(alignment: .topLeading) {
                Text("Reply to Claude").font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).frame(height: 36)
                    .glassEffect(.regular, in: .capsule)
                chip.alignmentGuide(.top) { $0[.bottom] + 8 }.padding(.leading, 6)
            }
        }
        .padding(10)
        .frame(height: 138)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .top) { if hairline { Hairline() } }
        .background(theme.colors.bg.color)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.quaternary))
        .padding(.horizontal, 16)
    }
}

/// The "Updating" chip as `ConnectionChip` drew it (spinner, one word, glass capsule), for the
/// before screen and variant C.
private struct UpdatingChipReplica: View {
    var body: some View {
        let theme = CmuxMobileTheme.standard
        HStack(spacing: 5) {
            CmuxSpinner().controlSize(.mini)
            Text(verbatim: "Updating").lineLimit(1)
        }
        .font(theme.type.meta.weight(.semibold))
        .foregroundStyle(theme.colors.label2)
        .fixedSize()
        .padding(.horizontal, 10)
        .frame(height: 26)
        .glassEffect(.regular, in: .capsule)
    }
}

/// Variant B: a 2 pt progress line across the top of the content.
private struct Hairline: View {
    var body: some View {
        ProgressView(value: 0.4)
            .progressViewStyle(.linear)
            .scaleEffect(x: 1, y: 0.6, anchor: .top)
    }
}
#endif
