#if os(iOS)
import SwiftUI

/// "Allow on this phone": another device asks a Mac to pair, and the person answers here instead
/// of clicking on the Mac (ask-45c37458ea). Shows the asking device, the Mac it asks, and the
/// fingerprint to match with the one the asking device shows.
public struct PairRequestCardView: View {
    let deviceName: String
    let macName: String
    let fingerprint: String
    let answering: Bool
    let failed: Bool
    let onAllow: () -> Void
    let onDeny: () -> Void

    public init(
        deviceName: String, macName: String, fingerprint: String, answering: Bool, failed: Bool,
        onAllow: @escaping () -> Void, onDeny: @escaping () -> Void
    ) {
        self.deviceName = deviceName
        self.macName = macName
        self.fingerprint = fingerprint
        self.answering = answering
        self.failed = failed
        self.onAllow = onAllow
        self.onDeny = onDeny
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(String(localized: "pairRequest.title", defaultValue: "Allow on this phone", bundle: .module),
                  systemImage: "lock.shield")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(String(
                format: String(localized: "pairRequest.asks", defaultValue: "“%1$@” wants to connect to %2$@", bundle: .module),
                deviceName, macName))
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "pairRequest.fingerprint", defaultValue: "Check it shows the same code:", bundle: .module))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(fingerprint)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .accessibilityIdentifier("pairRequest.fingerprint")
            }
            if failed {
                Text(String(localized: "pairRequest.failed",
                            defaultValue: "Your Mac didn’t take the answer. Try again.", bundle: .module))
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            HStack(spacing: 12) {
                Button(role: .cancel, action: onDeny) {
                    Text(String(localized: "pairRequest.deny", defaultValue: "Don’t Allow", bundle: .module))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("pairRequest.deny")
                Button(action: onAllow) {
                    Text(String(localized: "pairRequest.allow", defaultValue: "Allow", bundle: .module))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("pairRequest.allow")
            }
            .controlSize(.large)
            .disabled(answering)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}
#endif
