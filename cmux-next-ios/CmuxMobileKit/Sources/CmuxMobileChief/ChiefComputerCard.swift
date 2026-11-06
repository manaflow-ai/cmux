#if os(iOS)
import SwiftUI

/// Chief info's Computer card, in Messages' Find My slot: "<name>'s Computer" as the section
/// header, the Chief's computer's screen at 16:10 clipped to the card's top corners, then its
/// state. View only: the screen takes no touches. Hidden (no section at all) when
/// ``ChiefComputer/shown`` is nil. Its screen refreshes only while the card is on screen and the
/// app is active (``ChiefComputer/follow(chief:name:)`` runs in ``ChiefSettingsView``'s task).
struct ChiefComputerSection: View {
    let computer: ChiefComputer

    var body: some View {
        if let shown = computer.shown {
            Section {
                ChiefComputerScreen(state: shown.state, frame: computer.frame, title: shown.title)
                    .listRowInsets(EdgeInsets())
                HStack {
                    Text(shown.state.title)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("chief.settings.computer.state")
            } header: {
                Text(shown.title)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("chief.settings.computer")
            }
            .listRowBackground(ChiefInfoGeometry.card)
        }
    }
}

/// Geometry of the Computer card's screen.
enum ChiefComputerGeometry {
    /// iOS 26's inset grouped card corner: the screen fills the card's top.
    static let cardCorner: CGFloat = 26
    /// The computer's screen (1280x800).
    static let aspect: CGFloat = 16.0 / 10.0
}

/// The card's screen: the newest frame, or a dark screen saying why there is none.
private struct ChiefComputerScreen: View {
    let state: ChiefComputerState
    let frame: CGImage?
    let title: String

    var body: some View {
        ZStack {
            Color.black
            switch state {
            case .live:
                if let frame {
                    Image(decorative: frame, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .accessibilityElement()
                        .accessibilityLabel(String(localized: "Screen of \(title)"))
                        .accessibilityIdentifier("chief.settings.computer.screen")
                } else {
                    ProgressView().tint(.white)
                }
            case .asleep:
                message(String(localized: "Computer is asleep"), symbol: "moon.zzz.fill")
                    .accessibilityIdentifier("chief.settings.computer.asleep")
            case .waking:
                VStack(spacing: 8) {
                    ProgressView().tint(.white)
                    Text(String(localized: "Waking up…"))
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.8))
                }
                .accessibilityElement(children: .combine)
            case .unavailable:
                message(String(localized: "Computer isn't available"), symbol: nil)
            }
        }
        .aspectRatio(ChiefComputerGeometry.aspect, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(.rect(topLeadingRadius: ChiefComputerGeometry.cardCorner,
                         topTrailingRadius: ChiefComputerGeometry.cardCorner, style: .continuous))
        .environment(\.colorScheme, .dark)
        .allowsHitTesting(false)
    }

    private func message(_ text: String, symbol: String?) -> some View {
        VStack(spacing: 8) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.title)
                    .foregroundStyle(.white.opacity(0.8))
                    .accessibilityHidden(true)
            }
            Text(text)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
    }
}
#endif
