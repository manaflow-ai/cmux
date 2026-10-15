import CmuxBrowser
import SwiftUI

/// The Chromium panel's permission prompt strip (design spec §4, v1.1): a
/// non-modal row docked directly under the toolbar, full page width, drawn
/// over the top of the page without resizing it, so it reads as the toolbar
/// growing a row. It asks the first waiting question of the panel's
/// ``BrowserPermissionPromptQueue``, never takes focus, and no key answers
/// it, so Escape or Return typed into the page never decides a permission by
/// accident.
///
/// Host-agnostic: overlay it on the page area (it fills it and draws only the
/// strip). `mountCard` wraps just the strip, so a Chromium panel passes
/// `.browserPageOccluding(panel.pageOverlays, id: "permissionPrompt")` and
/// Chromium's child window is masked under the strip only (§0.9); with no
/// corners and no shadow nothing else shows through the hole.
///
/// References: design spec §4; cmux-design-references
/// `apps/t3-code/live/approval-command-and-thread-details.png` (approval strip
/// docked to the surface it gates) and
/// `apps/codex/web/computer-use-app-approval.webp` (copy and button order);
/// Next `PromptBarView.swift`; Chrome `components/permissions_strings.grdp`.
struct BrowserPermissionPromptBar: View {
    let queue: BrowserPermissionPromptQueue
    let metrics: BrowserChromeMetrics
    /// The toolbar's background (`resolvedBrowserChromeBackgroundColor`).
    let backgroundColor: Color
    var mountCard: (AnyView) -> AnyView = { $0 }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                if let prompt = queue.current {
                    mountCard(AnyView(
                        BrowserPermissionPromptStrip(
                            prompt: prompt,
                            metrics: metrics,
                            backgroundColor: backgroundColor,
                            isNarrow: proxy.size.width < BrowserChromeMetrics.promptStripNarrowPaneWidth
                        ) { answer in
                            queue.answer(prompt.id, with: answer)
                        }
                    ))
                    .id(prompt.id)
                    .transition(stripTransition)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: queue.current?.id)
        }
    }

    /// Opacity only: a slide over a live page reads as jank (spec §4).
    private var stripTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity,
            removal: .opacity.animation(reduceMotion ? nil : .easeOut(duration: 0.08))
        )
    }
}

private struct BrowserPermissionPromptStrip: View {
    let prompt: BrowserPermissionPrompt
    let metrics: BrowserChromeMetrics
    let backgroundColor: Color
    let isNarrow: Bool
    let answer: (BrowserPermissionPromptAnswer) -> Void

    var body: some View {
        Group {
            if isNarrow {
                // Spec §4: under 420 pt the buttons wrap to a second row, trailing.
                VStack(alignment: .trailing, spacing: metrics.promptStripSpacing / 2) {
                    question
                    buttons
                }
            } else {
                HStack(alignment: .center, spacing: metrics.promptStripSpacing) {
                    question
                    buttons
                }
            }
        }
        .padding(.vertical, metrics.promptStripVerticalPadding)
        .padding(.horizontal, metrics.promptStripHorizontalPadding)
        .frame(maxWidth: .infinity, minHeight: metrics.promptStripMinHeight)
        .background(backgroundColor)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 0.5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(BrowserPermissionPromptText.accessibilityLabel)
    }

    private var question: some View {
        HStack(alignment: .center, spacing: metrics.promptStripSpacing) {
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
        }
    }

    private var buttons: some View {
        HStack(spacing: metrics.promptStripSpacing / 2) {
            switch prompt.style {
            case .captureDevices:
                button(BrowserPermissionPromptText.neverAllow, prominent: false) { answer(.block) }
                button(BrowserPermissionPromptText.allowThisTime, prominent: false) { answer(.allowOnce) }
                button(BrowserPermissionPromptText.allowWhileVisiting, prominent: true) { answer(.allowAndRemember) }
            case .blockOrAllow:
                button(BrowserPermissionPromptText.block, prominent: false) { answer(.block) }
                button(BrowserPermissionPromptText.allow, prominent: true) { answer(prompt.allowAnswer) }
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

    /// Names the strip for VoiceOver (it is not modal).
    static var accessibilityLabel: String {
        String(localized: "browser.permission.prompt.accessibilityLabel", defaultValue: "Permission request")
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
