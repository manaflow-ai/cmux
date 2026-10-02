#if canImport(UIKit)
import CMUXMobileCore
import CmuxMobileSupport
import SwiftUI

struct BrowserStreamDialogCard: View {
    let dialog: MobileBrowserDialogEvent
    let respond: (MobileBrowserDialogRespondParameters) -> Void

    @State private var text: String
    @State private var username: String
    @State private var password = ""

    init(
        dialog: MobileBrowserDialogEvent,
        respond: @escaping (MobileBrowserDialogRespondParameters) -> Void
    ) {
        self.dialog = dialog
        self.respond = respond
        _text = State(initialValue: dialog.textField?.initial ?? "")
        _username = State(
            initialValue: dialog.kind == .httpBasicAuthentication
                ? (dialog.textField?.initial ?? "")
                : ""
        )
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.48).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(dialog.title ?? fallbackTitle)
                        .font(.headline)
                    if let message = dialog.message, !message.isEmpty {
                        Text(message)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else if let fallbackDetail {
                        Text(fallbackDetail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if dialog.title == nil, let host = dialog.host, !host.isEmpty {
                        Text(host)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                dialogFields

                // Match native alert convention: two short buttons sit side by
                // side, but three-plus (the insecure-HTTP interstitial) or a
                // long label overflow an HStack, so stack vertically instead.
                if dialog.buttons.count <= 2, !hasLongButtonLabel {
                    HStack(spacing: 10) {
                        ForEach(dialog.buttons, id: \.id) { button in
                            dialogButton(button)
                        }
                    }
                } else {
                    VStack(spacing: 8) {
                        ForEach(dialog.buttons, id: \.id) { button in
                            dialogButton(button)
                        }
                    }
                }
            }
            .padding(22)
            .frame(maxWidth: 420)
            .mobileGlassField(cornerRadius: 24)
            .padding(24)
        }
        .accessibilityIdentifier("BrowserStreamDialog")
    }

    @ViewBuilder
    private var dialogFields: some View {
        if dialog.kind == .httpBasicAuthentication {
            TextField(
                L10n.string(
                    "mobile.browserStream.dialog.username",
                    defaultValue: "Username"
                ),
                text: $username
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
            .textContentType(.username)
            .browserDialogFieldWell()

            SecureField(
                dialog.textField?.placeholder
                    ?? L10n.string(
                        "mobile.browserStream.dialog.password",
                        defaultValue: "Password"
                    ),
                text: $password
            )
            .textContentType(.password)
            .browserDialogFieldWell()
        } else if let field = dialog.textField {
            if field.secure {
                SecureField(field.placeholder ?? inputPlaceholder, text: $text)
                    .textContentType(.password)
                    .browserDialogFieldWell()
            } else {
                TextField(field.placeholder ?? inputPlaceholder, text: $text)
                    .browserDialogFieldWell()
            }
        }
    }

    @ViewBuilder
    private func dialogButton(_ button: MobileBrowserDialogButton) -> some View {
        if button.role == .destructive {
            Button(role: .destructive) { submit(button) } label: {
                Text(button.label).frame(maxWidth: .infinity)
            }
            .mobileGlassButton()
            .accessibilityIdentifier("BrowserStreamDialogButton-\(button.id)")
        } else {
            Button { submit(button) } label: {
                Text(button.label).frame(maxWidth: .infinity)
            }
            .modifier(BrowserStreamDialogButtonStyle(prominent: button.role == .default))
            .accessibilityIdentifier("BrowserStreamDialogButton-\(button.id)")
        }
    }

    private var fallbackTitle: String {
        if dialog.informational {
            return L10n.string(
                "mobile.browserStream.dialog.needsMac",
                defaultValue: "Needs Your Mac"
            )
        }
        if dialog.kind == .mediaCapturePermission {
            return L10n.string(
                "mobile.browserStream.dialog.mediaTitle",
                defaultValue: "Media Access"
            )
        }
        return L10n.string(
            "mobile.browserStream.dialog.requestTitle",
            defaultValue: "Browser Request"
        )
    }

    private var hasLongButtonLabel: Bool {
        dialog.buttons.contains { $0.label.count > 12 }
    }

    private var inputPlaceholder: String {
        L10n.string(
            "mobile.browserStream.dialog.input",
            defaultValue: "Enter text"
        )
    }

    private var fallbackDetail: String? {
        if dialog.informational {
            return L10n.string(
                "mobile.browserStream.dialog.needsMacDetail",
                defaultValue: "Complete this request on your Mac, or cancel it here."
            )
        }
        if dialog.kind == .mediaCapturePermission {
            return L10n.string(
                "mobile.browserStream.dialog.mediaDetail",
                defaultValue: "This site wants to use your camera or microphone."
            )
        }
        return nil
    }

    private func submit(_ button: MobileBrowserDialogButton) {
        let responseText: String?
        if button.role == .cancel {
            responseText = nil
        } else if dialog.kind == .httpBasicAuthentication {
            responseText = username + "\0" + password
        } else if dialog.textField != nil {
            responseText = text
        } else {
            responseText = nil
        }
        respond(MobileBrowserDialogRespondParameters(
            panelID: dialog.panelID,
            dialogID: dialog.dialogID,
            buttonID: button.id,
            text: responseText
        ))
    }
}

extension View {
    /// Renders a dialog text field as a visibly inset input well.
    ///
    /// The dialog card is itself glass, so a glass field background disappears
    /// into it and the field reads as a label; a filled well with a hairline
    /// border keeps the editable area obvious (same fill language as the
    /// bottom bar's address field).
    fileprivate func browserDialogFieldWell() -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return padding(12)
            .background(.quaternary.opacity(0.55), in: shape)
            .overlay(shape.strokeBorder(.separator.opacity(0.6), lineWidth: 1))
    }
}
#endif
