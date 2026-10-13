import AppKit
import SwiftUI

/// The pairing window: a QR code on the left, paired phones on the right.
struct PhonePairingView: View {
    @Bindable var model: PhonePairingModel
    @Environment(\.displayScale) private var displayScale
    @State private var code: CGImage?

    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            codeColumn
                .frame(width: 260)
            devicesColumn
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 28)
        .padding(.top, 36)
        .padding(.bottom, 22)
        .frame(width: PhonePairingWindowController.size.width - 24, height: PhonePairingWindowController.size.height - 24)
    }

    // MARK: Code

    private var codeColumn: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white)
                if let failure = model.failure {
                    Text(PhonePairingStrings.unavailable(failure))
                        .font(.system(size: 12))
                        .foregroundStyle(.black.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .padding(18)
                } else if let name = model.justPaired {
                    VStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 44, weight: .regular))
                            .foregroundStyle(.black)
                        Text(PhonePairingStrings.paired(name))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.black)
                            .multilineTextAlignment(.center)
                    }
                    .padding(18)
                } else if model.link != nil, let code {
                    Image(decorative: code, scale: displayScale)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 216, height: 216)
                        .accessibilityLabel(PhonePairingStrings.qrLabel)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 244, height: 244)
            .task(id: model.link) { await renderCode() }

            if model.failure == nil {
                HStack(spacing: 8) {
                    Button(PhonePairingStrings.newCode) { model.onNewCode() }
                    Button(PhonePairingStrings.copyLink) {
                        guard let link = model.link else { return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(link, forType: .string)
                    }
                    .disabled(model.link == nil || model.justPaired != nil)
                }
                .controlSize(.regular)
                if let code = model.code, model.justPaired == nil {
                    VStack(spacing: 2) {
                        Text(PhonePairingStrings.orType)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text(code)
                            .font(.system(size: 20, weight: .semibold, design: .monospaced))
                            .textSelection(.enabled)
                            .accessibilityLabel(PhonePairingStrings.codeLabel(code))
                    }
                }
                if let expiresAt = model.expiresAt, model.justPaired == nil {
                    Text(PhonePairingStrings.expires(expiresAt.formatted(date: .omitted, time: .shortened)))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Renders the QR code for the current link off the main actor.
    private func renderCode() async {
        guard let link = model.link else {
            code = nil
            return
        }
        let pixels = 216 * displayScale
        let image = await Task.detached(priority: .userInitiated) { QRCodeImage().make(link, pixels: pixels) }.value
        if model.link == link { code = image }
    }

    // MARK: Devices

    private var devicesColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(PhonePairingStrings.title)
                .font(.system(size: 20, weight: .semibold))
            Text(PhonePairingStrings.subtitle)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)

            Text(PhonePairingStrings.devices)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.top, 22)
                .padding(.bottom, 6)

            if model.phones.isEmpty {
                Text(PhonePairingStrings.noDevices)
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 10)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(model.phones) { phone in
                            PhoneRow(phone: phone, onRevoke: { model.onRevoke(phone.id) })
                        }
                    }
                }
                .frame(maxHeight: 190)
            }

            Spacer(minLength: 12)

            VStack(alignment: .leading, spacing: 4) {
                Label(PhonePairingStrings.encrypted(model.hostFingerprint), systemImage: "lock.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if let discoverable = model.discoverable {
                    Label(discoverable ? PhonePairingStrings.discoverable : PhonePairingStrings.notDiscoverable,
                          systemImage: discoverable ? "dot.radiowaves.left.and.right" : "exclamationmark.triangle")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                if !model.endpoints.isEmpty {
                    Text(PhonePairingStrings.reachable(model.endpoints.prefix(3).joined(separator: ", ")))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

private struct PhoneRow: View {
    let phone: PhonePairingModel.Phone
    let onRevoke: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "iphone")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(phone.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Circle()
                        .fill(phone.connected ? Color.green : Color.secondary.opacity(0.5))
                        .frame(width: 6, height: 6)
                    Text(status)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(PhonePairingStrings.unpair, role: .destructive, action: onRevoke)
                .buttonStyle(.borderless)
                .font(.system(size: 12))
                .opacity(hovering ? 1 : 0.55)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(hovering ? 0.06 : 0)))
        .onHover { hovering = $0 }
    }

    private var status: String {
        if phone.connected { return PhonePairingStrings.connected }
        if let lastSeen = phone.lastSeen {
            return PhonePairingStrings.lastSeen(lastSeen.formatted(.relative(presentation: .named)))
        }
        return PhonePairingStrings.notConnected
    }
}
