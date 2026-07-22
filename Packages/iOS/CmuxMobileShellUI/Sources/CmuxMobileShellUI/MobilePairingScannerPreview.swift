#if os(iOS)
import CmuxMobileSupport
import SwiftUI

/// A deterministic camera-free scanner surface for DEBUG UI verification.
struct MobilePairingScannerPreview: View {
    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer(minLength: 24)

                ZStack {
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .fill(.white.opacity(0.08))
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .stroke(.white.opacity(0.8), lineWidth: 3)

                    Image(systemName: "qrcode")
                        .font(.system(size: 132, weight: .light))
                        .foregroundStyle(.white)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: 280, maxHeight: 280)
                .aspectRatio(1, contentMode: .fit)

                Text(L10n.string(
                    "mobile.pairing.scannerInstruction",
                    defaultValue: "Position the Mac's QR code in the frame."
                ))
                .font(.headline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .padding(.horizontal, 32)

                Spacer(minLength: 24)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("MobilePairingScannerPreview")
    }
}
#endif
