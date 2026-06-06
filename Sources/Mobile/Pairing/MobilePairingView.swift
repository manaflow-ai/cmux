import SwiftUI

/// The macOS onboarding window for pairing an iPhone with this Mac.
///
/// Shows a scannable QR code (with a host:port fallback), step-by-step
/// instructions, and the current pairing-host state. Opening the window
/// turns the pairing listener on automatically.
struct MobilePairingView: View {
    @State private var model = MobilePairingModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                content
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await model.refresh() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "desktopcomputer.and.iphone")
                .font(.system(size: 28))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "mobile.pairing.window.heading", defaultValue: "Pair your iPhone"))
                    .font(.title2.weight(.semibold))
                Text(String(localized: "mobile.pairing.window.subheading", defaultValue: "Scan this code with the cmux app on your iPhone to sync your terminal workspaces."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .preparing:
            preparing
        case let .failed(message):
            failure(message: message)
        case let .ready(ready):
            readyContent(ready)
        }
    }

    private var preparing: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(String(localized: "mobile.pairing.preparing", defaultValue: "Preparing a pairing code…"))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 240)
    }

    private func failure(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundStyle(.orange)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button(String(localized: "mobile.pairing.retry", defaultValue: "Try Again")) {
                Task { await model.refresh() }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, minHeight: 240)
    }

    @ViewBuilder
    private func readyContent(_ ready: MobilePairingModel.Ready) -> some View {
        VStack(alignment: .center, spacing: 14) {
            MobilePairingQRImageView(payload: ready.attachURL, dimension: 220)
                .padding(12)
                .background(.white, in: RoundedRectangle(cornerRadius: 16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(Color.secondary.opacity(0.2))
                )

            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(String(localized: "mobile.pairing.waiting", defaultValue: "Waiting for your iPhone…"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)

        steps

        manualFallback(ready)

        HStack {
            Spacer()
            Button(String(localized: "mobile.pairing.refresh", defaultValue: "Refresh Code")) {
                Task { await model.refresh() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 10) {
            step(1, String(localized: "mobile.pairing.step.install", defaultValue: "Install cmux on your iPhone and open it."))
            step(2, String(localized: "mobile.pairing.step.signIn", defaultValue: "Sign in with the same account you use on this Mac."))
            step(3, String(localized: "mobile.pairing.step.scan", defaultValue: "Tap Add device, then Scan QR Code, and point the camera at the code above."))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Color.accentColor, in: Circle())
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func manualFallback(_ ready: MobilePairingModel.Ready) -> some View {
        if !ready.routeLines.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "mobile.pairing.manual.title", defaultValue: "Can't scan? Add this Mac manually:"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(ready.routeLines, id: \.self) { line in
                    Text(line)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}
