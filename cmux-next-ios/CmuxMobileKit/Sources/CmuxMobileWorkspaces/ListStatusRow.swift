#if os(iOS)
import CmuxMobileDesign
import CmuxSpinner
import SwiftUI

/// The quiet line at the top of a list whose rows stay on screen while it reads again: updating,
/// reconnecting to the Mac (a blip the list rides out on its own), or showing the rows read last
/// (the Mac stayed unreachable). Never an alert, never a raw timeout (Leo 2026-11-21). Picked
/// in the recovery gallery's `reconnect` scene (variant A) over a floating pill and a top bar.
public struct ListStatusRow: View {
    public enum State: Equatable, Sendable {
        case updating
        case reconnecting
        case stale
    }

    let state: State

    public init(_ state: State) { self.state = state }

    private var text: LocalizedStringKey {
        switch state {
        case .updating: "Updating…"
        case .reconnecting: "Reconnecting to your Mac…"
        case .stale: "Can't reach your Mac. Showing chats from earlier."
        }
    }

    public var body: some View {
        let theme = CmuxMobileTheme.standard
        HStack(spacing: 8) {
            if state == .stale {
                Image(systemName: "wifi.exclamationmark")
                    .font(.footnote)
                    .foregroundStyle(theme.colors.label3.color)
            } else {
                CmuxSpinner().controlSize(.small)
            }
            Text(text)
                .font(.footnote)
                .foregroundStyle(theme.colors.label2.color)
        }
        .frame(maxWidth: .infinity)
        .listRowBackground(Color.clear)
        .accessibilityElement(children: .combine)
        .animation(.easeInOut(duration: 0.2), value: state)
    }
}
#endif
