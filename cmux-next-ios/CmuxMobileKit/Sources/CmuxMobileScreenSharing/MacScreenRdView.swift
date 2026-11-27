#if os(iOS)
import CmuxMobileBrowserStream
import CmuxMobileDesign
import SwiftUI

/// A joined Mac's screen over `cmux.rd/1` (a `cmux://mac-screen` link): the picture whole on
/// black, and Close. A view session shows no touch or keyboard controls and takes no input; a
/// control session takes touches as the Mac's pointer and has a keyboard button.
struct MacScreenRdView: View {
    let model: StreamedBrowserModel
    let title: String
    let control: Bool
    let close: () -> Void

    var body: some View {
        ZStack {
            if control {
                StreamedTouchSurface(model: model, label: title, identifier: "macScreen.stream")
            } else {
                StreamedViewOnlySurface(model: model, label: title, identifier: "macScreen.stream")
            }
            status
            if StreamedBrowserOverlay.enabled {
                // The measurement meter (DEBUG, or `-cmux-mobile-browser-meter`), as the browser and
                // simulator pages draw it: bottom left, clear of Close and Keyboard at the top right.
                StreamedBrowserOverlay(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(.bottom, 24)
                    .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea()
        .background(Color.black.ignoresSafeArea())
        .overlay(alignment: .topTrailing) { buttons }
        .environment(\.colorScheme, .dark)
        .onAppear {
            model.setVisible(true)
            model.reconnect()
        }
        .onDisappear { model.setVisible(false) }
    }

    @ViewBuilder private var status: some View {
        switch model.phase {
        case .connecting:
            label(String(localized: "Connecting to \(title)…"))
                .placeholderBound("screenSharing.rd.connecting", .milliseconds(2000))
        case let .waiting(reason):
            label(reason)
        case .live, .unavailable:
            EmptyView()
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .glassEffect(.regular, in: .capsule)
            .padding(.horizontal, 24)
            .accessibilityIdentifier("macScreen.status")
    }

    private var buttons: some View {
        HStack(spacing: 12) {
            if control {
                button(model.wantsKeyboard ? String(localized: "Hide Keyboard") : String(localized: "Keyboard"),
                       model.wantsKeyboard ? "keyboard.chevron.compact.down" : "keyboard", "macScreen.keyboard") {
                    model.wantsKeyboard.toggle()
                }
            }
            button(String(localized: "Close"), "xmark", "macScreen.close", action: close)
        }
        .padding(16)
    }

    private func button(_ title: String, _ symbol: String, _ id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.cmuxPressGlass)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(title)
        .accessibilityIdentifier(id)
    }
}
#endif
