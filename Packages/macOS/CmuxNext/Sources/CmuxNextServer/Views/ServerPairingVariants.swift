import SwiftUI

/// `code`: large code, small QR, the four words.
struct CodeFirst: View {
    let offer: PairingOffer
    @Environment(\.serverColors) private var colors

    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 6) {
                Text(verbatim: offer.displayCode)
                    .font(.system(size: 34, weight: .semibold, design: .monospaced)).tracking(2)
                    .foregroundStyle(colors.primary).textSelection(.enabled)
                Text(ServerStrings.enterCode).font(.system(size: 11.5)).foregroundStyle(colors.secondary)
            }
            .padding(.vertical, 6)
            HStack(alignment: .center, spacing: 12) {
                QRCodeImage(payload: offer.qrPayload).frame(width: 92, height: 92)
                VStack(alignment: .leading, spacing: 6) {
                    WordsGrid(words: offer.words, size: 12)
                    Text(ServerStrings.wordsMatch).font(.system(size: 10.5)).foregroundStyle(colors.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// `qr`: large QR, code below.
struct QRFirst: View {
    let offer: PairingOffer
    @Environment(\.serverColors) private var colors

    var body: some View {
        VStack(spacing: 10) {
            QRCodeImage(payload: offer.qrPayload).frame(width: 196, height: 196)
                .padding(8).background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white))
            Text(ServerStrings.scan).font(.system(size: 12)).foregroundStyle(colors.secondary)
            Text(verbatim: offer.displayCode)
                .font(.system(size: 20, weight: .semibold, design: .monospaced)).tracking(1.5)
                .foregroundStyle(colors.primary).textSelection(.enabled)
            Text(verbatim: offer.words.joined(separator: " · "))
                .font(.system(size: 11.5, design: .rounded)).foregroundStyle(colors.tertiary)
        }
    }
}

/// `words`: the four words as the primary check, the code in a field (for
/// reading aloud).
struct WordsFirst: View {
    let offer: PairingOffer
    @Environment(\.serverColors) private var colors

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(ServerStrings.wordsMatch).font(.system(size: 12)).foregroundStyle(colors.secondary)
            WordsGrid(words: offer.words, size: 17)
            HStack(spacing: 8) {
                Text(ServerStrings.code).font(.system(size: 11.5)).foregroundStyle(colors.tertiary)
                Text(verbatim: offer.displayCode)
                    .font(.system(size: 15, weight: .medium, design: .monospaced)).tracking(1)
                    .foregroundStyle(colors.primary).textSelection(.enabled)
                Spacer()
            }
            .padding(.horizontal, 10).frame(height: 32)
            .card(radius: 8)
        }
    }
}
