import CmuxNextDesign
import SwiftUI

/// The selected report in the Labs reports basket: its sender, when it arrived, its text, and a
/// reply field whose Reply button sends `draft` through `onSend`. `sending`: a reply is in flight
/// (the button waits for it); `notSent`: the last reply was not sent.
struct ReportsBasketDetail: View {
    let item: FeedReport
    @Binding var draft: String
    let sending: Bool
    let notSent: Bool
    let onSend: () -> Void
    @Environment(\.feedColors) private var colors

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text(item.sender).font(.system(size: TypeScale.title, weight: .semibold))
                Text(FeedStrings.reportFrom(item.sender, item.createdAt.formatted(date: .long, time: .shortened)))
                    .font(.system(size: TypeScale.caption)).foregroundStyle(colors.tertiary)
            }
            .padding(18)
            FeedHairline()
            ScrollView {
                Text(item.body.isEmpty ? FeedStrings.reportsEmptyBody : item.body)
                    .font(.system(size: TypeScale.body)).foregroundStyle(colors.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
            }
            Spacer(minLength: 0)
            FeedHairline()
            if notSent {
                Text(FeedStrings.reportsNotSent)
                    .font(.system(size: TypeScale.caption)).foregroundStyle(colors.danger)
                    .padding(.horizontal, 14).padding(.top, 10)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(FeedStrings.reportsReplyPlaceholder, text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(1...4).focusEffectDisabled()
                Button(FeedStrings.reportsReply, action: onSend).buttonStyle(.borderedProminent)
                    .disabled(sending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(14)
        }
        .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
    }
}
