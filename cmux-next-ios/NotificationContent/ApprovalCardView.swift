import CmuxMobileNotifications
import SwiftUI
import UIKit

/// A permission request's long-press view, laid out as the Mac's approval
/// prompt for a streaming device (`MacScreenApprovalView`): the accent glyph
/// and "<Agent> wants to act on <Mac>", the secondary "Asks to run this…"
/// line, the request under its caption in code type (where the Mac shows the
/// device key fingerprint), then Deny leading and Allow trailing, with any
/// other answer compact under them.
struct ApprovalCardView: View {
    let banner: ApprovalBanner
    let model: NotificationContentModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                // The Mac panel's glyph ink: the label color, not a hue.
                Image(systemName: ApprovalBanner.glyph).font(.title3).foregroundStyle(.primary)
                Text(banner.title).font(.headline).fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            Text(banner.scope).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let detail = banner.detail {
                VStack(alignment: .leading, spacing: 2) {
                    Text(banner.detailLabel).font(.caption).foregroundStyle(.secondary)
                    // Wraps in full, as the plain view showed it: what is approved is never cut.
                    // The Mac caps the title (PROTOCOL.md), so the card stays inside the long look.
                    Text(detail).font(.system(.callout, design: .monospaced))
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
            if model.sent {
                Label("Opening cmux to send…", systemImage: "paperplane").font(.footnote).foregroundStyle(.secondary)
            } else if let failure = model.failure {
                Text(failure).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            if model.actionable { answers }
        }
        // On the long look's own platter, as the plain view: no card drawn inside it.
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("cmux.push.approval")
    }

    @ViewBuilder
    private var answers: some View {
        if banner.deny != nil || banner.allow != nil {
            HStack(spacing: 8) {
                if let deny = banner.deny {
                    Button(role: .destructive) { model.tap(deny) } label: { Text(deny.label).frame(minWidth: 64) }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("cmux.push.option.\(deny.id)")
                }
                Spacer(minLength: 8)
                if let allow = banner.allow {
                    // The Mac's primary answer: label-colored fill, background-colored text, in both appearances.
                    Button { model.tap(allow) } label: {
                        Text(allow.label).frame(minWidth: 64).foregroundStyle(Color(uiColor: .systemBackground))
                    }
                        .buttonStyle(.borderedProminent)
                        .tint(.primary)
                        .accessibilityIdentifier("cmux.push.option.\(allow.id)")
                }
            }
            .controlSize(.regular)
        }
        if !banner.more.isEmpty {
            HStack(spacing: 8) {
                ForEach(banner.more) { row in
                    Button(role: row.style == .deny ? .destructive : nil) { model.tap(row) } label: { Text(row.label) }
                        .buttonStyle(.bordered)
                        .tint(row.style == .deny ? nil : .primary)
                        .controlSize(.small)
                        .accessibilityIdentifier("cmux.push.option.\(row.id)")
                }
            }
        }
    }
}
