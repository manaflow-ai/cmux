import SwiftUI

/// The install consent sheet (section 5.4): tier badge, publisher, scopes
/// with reasons and risk tones, the profile picker, Install.
struct ConsentSheetView: View {
    var model: AppConsentModel
    var style: AppPermissionsStyle
    @Environment(\.permissionColors) private var colors

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AppHeader(listing: model.listing)
            if model.listing.tier == .unverified {
                Label(AppPermissionsStrings.unverifiedWarning, systemImage: "exclamationmark.triangle")
                    .font(colors.caption)
                    .foregroundStyle(colors.warning)
            }
            PermissionsPresentation(style: style, tier: model.listing.tier, profile: model.draft.profile,
                                    rows: ScopeRows.consent(model.draft), actions: actions) { model.draft.setProfile($0) }
            HStack(spacing: 8) {
                Spacer()
                Button(AppPermissionsStrings.cancel) { model.cancel() }
                    .buttonStyle(PermissionButtonStyle(kind: .secondary))
                    .keyboardShortcut(.cancelAction)
                Button(AppPermissionsStrings.install) { model.install() }
                    .buttonStyle(PermissionButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(18)
    }

    private var actions: ScopeRowActions {
        ScopeRowActions(
            setOn: { scope, on in model.draft.set(scope, on: on) },
            setApproval: { scope, approval in
                if approval != .denied { model.draft.set(scope, on: true) }
                model.draft.setApproval(scope, approval)
            })
    }
}

/// App icon, name, tier and publisher.
struct AppHeader: View {
    var listing: AppPermissionsListing
    @Environment(\.permissionColors) private var colors

    var body: some View {
        HStack(spacing: 10) {
            AppGlyph(symbol: listing.symbol, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(listing.name).font(colors.title).foregroundStyle(colors.text).lineLimit(1)
                    TierBadge(tier: listing.tier)
                }
                Text(verbatim: "\(listing.publisher) · \(listing.version)")
                    .font(colors.caption).foregroundStyle(colors.tertiary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }
}

/// The inline first-use prompt for an optional scope (section 5.4). The
/// host draws it inside the app's surface; the app cannot draw one.
struct FirstUsePromptView: View {
    var prompt: AppFirstUsePrompt
    @Environment(\.permissionColors) private var colors

    var body: some View {
        let kind = AppScopeKind(prompt.scope)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                AppGlyph(symbol: prompt.listing.symbol, size: 18)
                Text(AppPermissionsStrings.promptTitle(app: prompt.listing.name))
                    .font(colors.caption).foregroundStyle(colors.secondary).lineLimit(1)
                Spacer(minLength: 4)
                Label(AppPermissionsStrings.promptSource, systemImage: "lock.shield")
                    .font(colors.caption).foregroundStyle(colors.tertiary).labelStyle(.titleAndIcon).lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                ToneDot(tone: kind.risk.tone)
                VStack(alignment: .leading, spacing: 2) {
                    Text(AppScopeStrings.title(prompt.scope)).font(colors.emphasized).foregroundStyle(colors.text)
                    if !prompt.reason.isEmpty {
                        Text(prompt.reason).font(colors.caption).foregroundStyle(colors.tertiary).lineLimit(3)
                    }
                }
            }
            HStack(spacing: 6) {
                Spacer()
                Button(AppPermissionsStrings.deny) { prompt.answer(.deny) }.buttonStyle(PermissionButtonStyle(kind: .quiet))
                Button(AppPermissionsStrings.allowOnce) { prompt.answer(.allowOnce) }.buttonStyle(PermissionButtonStyle(kind: .secondary))
                Button(AppPermissionsStrings.allow) { prompt.answer(.allow) }.buttonStyle(PermissionButtonStyle(kind: .primary))
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(colors.card))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(colors.tone(kind.risk.tone).opacity(kind.risk.tone == .neutral ? 0.3 : 0.6), lineWidth: 1))
    }
}
