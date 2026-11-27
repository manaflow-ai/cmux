#if os(iOS)
import CmuxMobileDesign
import SwiftUI

private let theme = CmuxMobileTheme.standard

/// Home's "Chief Is Off" card (``ChiefOffCard``), at the top of Home where
/// the Cloud Chief's row would be. The shape is SPEC 7.3's inline
/// `FailureCard`: `bg` with a 1 pt `separator` stroke, radius `cardRadius`,
/// padding 16, symbol and `emptyTitle` title, `rowSubtitle` body. The button
/// is the inline `PrimaryCapsule`, with its spinner while Turn On is out.
/// Gallery: `-cmux-mobile-recovery-gallery chiefoff` (A is this; B and C are
/// the variants it was picked from).
public struct ChiefOffCardView: View {
    /// How the card is drawn. Home uses ``card``.
    public enum Style: Sendable, Hashable {
        /// A: the inline failure card (picked).
        case card
        /// B: a centered note with the capsule under it, as Home's other notes.
        case note
        /// C: the Chief's own row, with the capsule at its trailing edge.
        case row
    }

    let card: ChiefOffCard
    let style: Style
    let name: String
    let turnOn: () -> Void

    public init(_ card: ChiefOffCard, style: Style = .card, name: String = String(localized: "Chief"), turnOn: @escaping () -> Void) {
        self.card = card
        self.style = style
        self.name = name
        self.turnOn = turnOn
    }

    static let title: LocalizedStringKey = "Chief Is Off"

    var message: LocalizedStringKey {
        switch card {
        case .off, .turningOn: "It doesn't answer messages until you turn it on."
        case .failed: "It couldn't be turned on. Check your connection and try again."
        case .unavailable: "Chief isn't available on this account."
        }
    }

    var buttonTitle: LocalizedStringKey { card == .failed ? "Try Again" : "Turn On" }

    public var body: some View {
        Group {
            switch style {
            case .card: cardBody
            case .note: noteBody
            case .row: rowBody
            }
        }
        .accessibilityIdentifier("home.chief.off")
        .accessibilityValue(Text(verbatim: "\(card)"))
    }

    @ViewBuilder private var button: some View {
        if card != .unavailable {
            PrimaryCapsule(buttonTitle, size: .inline, isLoading: card == .turningOn) {
                guard card.offersTurnOn else { return }
                theme.haptics.selection()
                turnOn()
            }
            .accessibilityIdentifier("home.chief.turnOn")
        }
    }

    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Image(systemName: "power").font(.system(size: 17)).accessibilityHidden(true)
                    Text(Self.title).font(theme.type.emptyTitle)
                }
                .foregroundStyle(theme.colors.label)
                Text(message).font(theme.type.rowSubtitle).foregroundStyle(theme.colors.label2)
            }
            .accessibilityElement(children: .combine)
            button
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(theme.colors.bg, in: .rect(cornerRadius: theme.metrics.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: theme.metrics.cardRadius, style: .continuous)
                .strokeBorder(theme.colors.separator, lineWidth: 1)
        }
    }

    private var noteBody: some View {
        VStack(spacing: 8) {
            VStack(spacing: 2) {
                Text(Self.title).font(.footnote.weight(.semibold)).foregroundStyle(theme.colors.label)
                Text(message).font(.footnote).foregroundStyle(theme.colors.label2)
            }
            .multilineTextAlignment(.center)
            .accessibilityElement(children: .combine)
            button
        }
        .frame(maxWidth: .infinity)
    }

    private var rowBody: some View {
        HStack(spacing: 12) {
            ChiefAvatar(text: ChiefIdentity.standard.avatar, size: 44)
                .opacity(0.5)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: name).font(theme.type.rowTitle).foregroundStyle(theme.colors.label)
                Text(message).font(theme.type.rowSubtitle).foregroundStyle(theme.colors.label2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            button
        }
    }
}
#endif
