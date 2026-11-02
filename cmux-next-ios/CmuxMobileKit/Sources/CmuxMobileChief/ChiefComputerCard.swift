#if os(iOS)
import CmuxMobileBrowserStream
import SwiftUI

/// Chief info's Computer card, in Messages' Find My slot: a "Computer"
/// section header, the Cloud machine's screen at its aspect ratio (16:10
/// until the first frame) clipped to the card's top corners, then a row with
/// the machine's name and state. View only: the screen takes no touches and
/// its stream sends none. Hidden (no section at all) when
/// ``ChiefComputer/shown`` is nil.
struct ChiefComputerSection: View {
    let computer: ChiefComputer

    var body: some View {
        if let shown = computer.shown, let state = computer.state {
            Section {
                ChiefComputerScreen(state: state, stream: shown.streamsDesktop ? computer.stream : nil,
                                    name: shown.machine.name)
                    .listRowInsets(EdgeInsets())
                HStack {
                    Text(shown.machine.name)
                        .lineLimit(1)
                    Spacer()
                    Text(state.title)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("chief.settings.computer.state")
            } header: {
                Text("Computer")
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
    /// The screen's aspect ratio before the first frame.
    static let placeholderAspect: CGFloat = 16.0 / 10.0
}

/// The card's screen: the live stream, or a dark screen saying why there is none.
private struct ChiefComputerScreen: View {
    let state: ChiefComputerState
    let stream: StreamedBrowserModel?
    let name: String

    var body: some View {
        ZStack {
            Color.black
            switch state {
            case .live:
                if let stream {
                    ChiefComputerLiveScreen(stream: stream, name: name)
                } else {
                    message(String(localized: "Computer isn't available"), symbol: nil)
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
        .aspectRatio(aspect, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(.rect(topLeadingRadius: ChiefComputerGeometry.cardCorner,
                         topTrailingRadius: ChiefComputerGeometry.cardCorner, style: .continuous))
        .environment(\.colorScheme, .dark)
    }

    /// The stream's picture's ratio once a frame came, else 16:10.
    private var aspect: CGFloat {
        guard state == .live, let meter = stream?.meter, meter.width > 0, meter.height > 0 else {
            return ChiefComputerGeometry.placeholderAspect
        }
        return CGFloat(meter.width) / CGFloat(meter.height)
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

/// The running machine's screen. Its stream is shown only while the card is
/// on screen and the app is active; it closes when the card leaves.
private struct ChiefComputerLiveScreen: View {
    let stream: StreamedBrowserModel
    let name: String
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            StreamedViewOnlySurface(model: stream, label: String(localized: "Screen of \(name)"),
                                    identifier: "chief.settings.computer.screen")
                .allowsHitTesting(false)
            if stream.phase != .live, stream.meter.frames == 0 {
                ProgressView().tint(.white)
            }
        }
        .onAppear {
            stream.setAppActive(scenePhase == .active)
            stream.setVisible(true)
            stream.reconnect()
        }
        .onDisappear {
            stream.setVisible(false)
            // Off screen, the Mac stops reading the machine's desktop.
            stream.close()
        }
        .onChange(of: scenePhase) { _, phase in stream.setAppActive(phase == .active) }
    }
}
#endif
