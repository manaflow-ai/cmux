import SwiftUI

/// The server's side of pairing: what it shows while it waits for a
/// signed-in device to approve (server.md 6.2 step 2).
struct ServerPairingView: View {
    let model: ServerModel
    let style: ServerPairingStyle
    @Environment(\.serverColors) private var colors

    var body: some View {
        VStack(spacing: 14) {
            ServerHeader(model: model)
            switch model.snapshot?.pairing {
            case let .unpaired(offer?)?:
                switch style {
                case .code: CodeFirst(offer: offer)
                case .qr: QRFirst(offer: offer)
                case .words: WordsFirst(offer: offer)
                }
                Text(ServerStrings.expires(ServerFormat.time(offer.expiresAt)))
                    .font(.system(size: 11)).foregroundStyle(colors.tertiary)
            case .unpaired(nil)?:
                PillButton(title: ServerStrings.pairThisServer, prominent: true, action: model.showPairingCode)
                    .padding(.vertical, 20)
            case .pairing?:
                PairedBadge(symbol: "link", title: ServerStrings.pairing, detail: nil)
            case let .paired(info)?:
                PairedBadge(symbol: "checkmark.seal", title: ServerStrings.paired, detail: "\(info.team) · \(info.owner)")
            case nil:
                EmptyView()
            }
        }
        .padding(ServerMetrics.padding + 2)
        .frame(width: ServerMetrics.panelWidth)
    }
}

struct PairedBadge: View {
    let symbol: String
    let title: String
    let detail: String?
    @Environment(\.serverColors) private var colors

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 30, weight: .light)).foregroundStyle(colors.secondary)
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(colors.primary)
            if let detail { Text(verbatim: detail).font(.system(size: 12)).foregroundStyle(colors.secondary) }
        }
        .padding(.vertical, 18)
    }
}
