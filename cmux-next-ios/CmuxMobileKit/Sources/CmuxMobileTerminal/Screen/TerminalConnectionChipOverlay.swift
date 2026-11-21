#if os(iOS)
import CmuxMobileDesign
import SwiftUI

extension View {
    /// The terminal's connection state as a small chip at the top center of
    /// the page, after its quiet 10 s (`TerminalModel.connectionChip`). An
    /// overlay: it never moves the composer or the rows (Leo, 2026-11-21:
    /// "these messages should not be pushing up the text ... stop layout
    /// shifting"). It replaces the line that grew the composer card.
    func terminalConnectionChip(_ model: TerminalModel, topInset: CGFloat = 0) -> some View {
        overlay(alignment: .top) {
            if let chip = model.connectionChip {
                ConnectionChip(chip, retry: model.reconnect)
                    .padding(.top, topInset + 6)
                    .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.2).unlessReduceMotion, value: model.connectionChip)
    }
}
#endif
