#if os(iOS)
import CmuxMobileDesign
import CmuxSpinner
import SwiftUI

/// Home's top bar while the Home Mac is not connected or its list failed (CMUX-489):
/// the same card as a conversation's "Not connected to your Mac" bar (CMUX-30), so the
/// two screens say a dropped Mac the same way. The whole bar is the Try Again button.
struct HomeConnectionBarView: View {
    let bar: HomeConnectionBar
    let retrying: Bool
    let retry: () async -> Void

    var body: some View {
        Button {
            guard !retrying else { return }
            Task { await retry() }
        } label: {
            HStack(spacing: 10) {
                if retrying {
                    CmuxSpinner().controlSize(.small)
                } else {
                    Image(systemName: bar.kind == .offline ? "wifi.exclamationmark" : "exclamationmark.triangle.fill")
                        .font(.body)
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(bar.title).font(.footnote.weight(.semibold))
                    Text(bar.detail).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(retrying ? String(localized: "Trying…") : String(localized: "Try Again"))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(retrying ? Color.secondary : Color.accentColor)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .contentShape(.rect)
            .background(Color(uiColor: .secondarySystemBackground), in: .rect(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(retrying)
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(bar.title). \(bar.detail)")
        .accessibilityHint(retrying ? "" : String(localized: "Tries to reach your Mac again"))
        .accessibilityIdentifier("home.note.problem")
        .accessibilityAddTraits(.isButton)
    }
}
#endif
