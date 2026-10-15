import CmuxBrowser
import SwiftUI

/// The Chromium panel's permission prompt bar (design spec §4): a non-modal
/// card at the top center of the page asking the first waiting question of
/// the panel's ``BrowserPermissionPromptQueue``. It never takes focus and no
/// key answers it, so Escape or Return typed into the page never decides a
/// permission by accident.
///
/// Host-agnostic: overlay it on the page area (it fills it and draws only the
/// card). `mountCard` wraps just the card, so a Chromium panel passes
/// `.browserPageOccluding(panel.pageOverlays, id: "permissionPrompt")` and
/// Chromium's child window is masked under the card only (chrome-ui's page
/// overlay host); other hosts keep the default identity.
///
/// References: Next `PromptBarView.swift` (answers and copy),
/// cmux-design-references `apps/codex/web/computer-use-app-approval.webp`
/// (inline approval card, primary action on the right), Chrome
/// `components/permissions_strings.grdp` (wording).
struct BrowserPermissionPromptBar: View {
    let queue: BrowserPermissionPromptQueue
    let metrics: BrowserChromeMetrics
    var mountCard: (AnyView) -> AnyView = { $0 }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                if let prompt = queue.current {
                    mountCard(AnyView(
                        BrowserPermissionPromptCard(prompt: prompt, metrics: metrics) { answer in
                            queue.answer(prompt.id, with: answer)
                        }
                        .frame(width: metrics.promptBarWidth(pageWidth: proxy.size.width))
                    ))
                    .id(prompt.id)
                    .transition(cardTransition)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, metrics.promptBarInset)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: queue.current?.id)
        }
    }

    private var cardTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(y: -4)),
            removal: .opacity.animation(.easeOut(duration: 0.08))
        )
    }
}

private struct BrowserPermissionPromptCard: View {
    let prompt: BrowserPermissionPrompt
    let metrics: BrowserChromeMetrics
    let answer: (BrowserPermissionPromptAnswer) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: metrics.promptBarPadding) {
            Image(systemName: BrowserPermissionPromptText.symbolName(for: prompt.kinds))
                .font(.system(size: metrics.promptBarIconFontSize))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(BrowserPermissionPromptText.message(for: prompt))
                .font(.system(size: metrics.promptBarMessageFontSize))
                .foregroundStyle(.primary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            buttons
        }
        .padding(metrics.promptBarPadding)
        .background(
            RoundedRectangle(cornerRadius: metrics.promptBarCornerRadius, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: metrics.promptBarCornerRadius, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.11), radius: metrics.promptBarShadowRadius, y: metrics.promptBarShadowOffsetY)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    @ViewBuilder
    private var buttons: some View {
        HStack(spacing: metrics.promptBarPadding / 2) {
            switch prompt.style {
            case .captureDevices:
                button(BrowserPermissionPromptText.neverAllow, prominent: false) { answer(.block) }
                button(BrowserPermissionPromptText.allowThisTime, prominent: false) { answer(.allowOnce) }
                button(BrowserPermissionPromptText.allowWhileVisiting, prominent: true) { answer(.allowAndRemember) }
            case .blockOrAllow:
                button(BrowserPermissionPromptText.block, prominent: false) { answer(.block) }
                button(BrowserPermissionPromptText.allow, prominent: true) { answer(.allowAndRemember) }
            }
        }
        .fixedSize()
    }

    @ViewBuilder
    private func button(_ title: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        let label = Text(title)
            .font(.system(size: metrics.promptBarButtonFontSize))
            .lineLimit(1)
            .frame(minHeight: metrics.promptBarButtonHeight)
        if prominent {
            Button(action: action) { label }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        } else {
            Button(action: action) { label }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }
}

/// Copy and glyphs of the permission prompt bar (design spec §4; Next
/// `Strings.swift`; Chrome `permissions_strings.grdp`).
enum BrowserPermissionPromptText {
    static var neverAllow: String {
        String(localized: "browser.permission.prompt.neverAllow", defaultValue: "Never allow")
    }

    static var allowThisTime: String {
        String(localized: "browser.permission.prompt.allowThisTime", defaultValue: "Allow this time")
    }

    static var allowWhileVisiting: String {
        String(localized: "browser.permission.prompt.allowWhileVisiting", defaultValue: "Allow while visiting the site")
    }

    static var block: String {
        String(localized: "browser.permission.prompt.block", defaultValue: "Block")
    }

    static var allow: String {
        String(localized: "browser.permission.prompt.allow", defaultValue: "Allow")
    }

    /// The SF Symbol of the capability asked about.
    static func symbolName(for kinds: [BrowserPagePermissionRequest.Kind]) -> String {
        switch kinds.first {
        case .camera?: "camera"
        case .microphone?: "mic"
        case .geolocation?: "location"
        case .notifications?: "bell"
        case .clipboardRead?: "doc.on.clipboard"
        default: "hand.raised"
        }
    }

    /// The question, with the origin in bold.
    static func message(for prompt: BrowserPermissionPrompt) -> AttributedString {
        let origin = prompt.displayOrigin
        let format: String
        switch Set(prompt.kinds) {
        case [.camera]:
            format = String(localized: "browser.permission.prompt.camera", defaultValue: "%@ wants to use your camera.")
        case [.microphone]:
            format = String(localized: "browser.permission.prompt.microphone", defaultValue: "%@ wants to use your microphone.")
        case [.camera, .microphone]:
            format = String(
                localized: "browser.permission.prompt.cameraAndMicrophone",
                defaultValue: "%@ wants to use your camera and microphone."
            )
        case [.geolocation]:
            format = String(localized: "browser.permission.prompt.location", defaultValue: "%@ wants to know your location.")
        case [.notifications]:
            format = String(localized: "browser.permission.prompt.notifications", defaultValue: "%@ wants to show notifications.")
        case [.clipboardRead]:
            format = String(
                localized: "browser.permission.prompt.clipboardRead",
                defaultValue: "%@ wants to see text and images copied to the clipboard."
            )
        default:
            format = String(localized: "browser.permission.prompt.generic", defaultValue: "%@ wants extra permissions.")
        }
        return boldingOrigin(origin, in: format)
    }

    /// Fills `%@` with `origin` and bolds exactly that span (never parsing
    /// the origin as markup).
    static func boldingOrigin(_ origin: String, in format: String) -> AttributedString {
        guard let placeholder = format.range(of: "%@") else { return AttributedString(format) }
        var result = AttributedString(String(format[..<placeholder.lowerBound]))
        var bold = AttributedString(origin)
        bold.inlinePresentationIntent = .stronglyEmphasized
        result += bold
        result += AttributedString(String(format[placeholder.upperBound...]))
        return result
    }
}
