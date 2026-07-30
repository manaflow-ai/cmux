import CmuxSettings
import SwiftUI

/// Interactive content hosted by DynamicNotchKit for one terminal notification.
struct DynamicNotchNotificationView: View {
    let notification: TerminalNotification
    let isTrayExpanded: Bool
    let shouldAutofocus: Bool
    let appearance: DynamicNotchAppearance
    let performAction: (String, [String: String]) -> Void
    @State private var values: [String: String]
    @FocusState private var focusedInputID: String?

    init(
        notification: TerminalNotification,
        isTrayExpanded: Bool,
        shouldAutofocus: Bool,
        appearance: DynamicNotchAppearance,
        performAction: @escaping (String, [String: String]) -> Void
    ) {
        self.notification = notification
        self.isTrayExpanded = isTrayExpanded
        self.shouldAutofocus = shouldAutofocus
        self.appearance = appearance
        self.performAction = performAction
        _values = State(initialValue: Dictionary(
            uniqueKeysWithValues: notification.presentation.inputs.map {
                ($0.id, $0.initialValue)
            }
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: appearance.dimension(.rowSpacing)) {
            HStack(alignment: .top, spacing: appearance.dimension(.headerSpacing)) {
                Image(systemName: notification.presentation.iconSymbolName ?? "bell.badge.fill")
                    .font(.system(
                        size: appearance.dimension(.notificationIconSize),
                        weight: .semibold
                    ))
                    .foregroundStyle(
                        appearance.color(.accentColor, system: .accentColor)
                    )
                    .frame(
                        width: appearance.dimension(.notificationIconFrame),
                        height: appearance.dimension(.notificationIconFrame)
                    )
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: appearance.dimension(.textSpacing)) {
                    Text(notification.title)
                        .font(.headline)
                        .foregroundStyle(
                            appearance.color(.primaryTextColor, system: .primary)
                        )
                        .lineLimit(appearance.integer(.titleLineLimit))
                    if !notification.subtitle.isEmpty {
                        Text(notification.subtitle)
                            .font(.subheadline)
                            .foregroundStyle(
                                appearance.color(.secondaryTextColor, system: .secondary)
                            )
                            .lineLimit(appearance.integer(.subtitleLineLimit))
                    }
                    if !notification.body.isEmpty {
                        Text(notification.body)
                            .font(.callout)
                            .foregroundStyle(
                                appearance.color(.secondaryTextColor, system: .secondary)
                            )
                            .lineLimit(appearance.integer(.bodyLineLimit))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    performAction("dismiss", values)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(
                            appearance.color(.closeButtonColor, system: .secondary)
                        )
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel(String(localized: "notification.dynamicNotch.dismiss", defaultValue: "Dismiss"))
                .accessibilityIdentifier("DynamicNotchNotificationDismiss")
            }

            if !notification.presentation.inputs.isEmpty {
                VStack(
                    alignment: .leading,
                    spacing: appearance.dimension(.inputSpacing)
                ) {
                    ForEach(notification.presentation.inputs, id: \.id) { input in
                        VStack(
                            alignment: .leading,
                            spacing: appearance.dimension(.inputLabelSpacing)
                        ) {
                            Text(input.label)
                                .font(.caption)
                                .foregroundStyle(
                                    appearance.color(
                                        .secondaryTextColor,
                                        system: .secondary
                                    )
                                )
                            Group {
                                if input.kind == .secure {
                                    SecureField(
                                        input.placeholder,
                                        text: valueBinding(for: input)
                                    )
                                } else {
                                    TextField(
                                        input.placeholder,
                                        text: valueBinding(for: input)
                                    )
                                }
                            }
                            .focused($focusedInputID, equals: input.id)
                            .modifier(
                                DynamicNotchInputAppearanceModifier(
                                    appearance: appearance
                                )
                            )
                        }
                        .accessibilityIdentifier("DynamicNotchNotificationInput.\(input.id)")
                    }
                }
            }

            HStack(spacing: appearance.dimension(.actionSpacing)) {
                ForEach(
                    Array(notification.presentation.actions.enumerated()),
                    id: \.element.id
                ) { index, action in
                    if index == 0 {
                        actionButton(action)
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                    } else {
                        actionButton(action)
                            .buttonStyle(.bordered)
                    }
                }

                if notification.presentation.actions.isEmpty {
                    Spacer(minLength: 0)

                    Button(String(localized: "notification.dynamicNotch.open", defaultValue: "Open")) {
                        performAction("open", values)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.small)
                    .accessibilityIdentifier("DynamicNotchNotificationOpen")
                }
            }
        }
        .padding(.horizontal, appearance.dimension(.rowHorizontalPadding))
        .padding(.top, appearance.dimension(.rowTopPadding))
        .padding(.bottom, appearance.dimension(.rowBottomPadding))
        .frame(maxWidth: .infinity)
        .background(
            appearance.color(.rowBackgroundColor, system: .clear)
                .opacity(Double(appearance.dimension(.rowBackgroundOpacity))),
            in: RoundedRectangle(
                cornerRadius: appearance.dimension(.rowCornerRadius),
                style: .continuous
            )
        )
        .tint(appearance.color(.accentColor, system: .accentColor))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("DynamicNotchNotification")
        .onAppear {
            updateAutomaticFocus()
        }
        .onChange(of: isTrayExpanded) { _, _ in
            updateAutomaticFocus()
        }
        .onChange(of: shouldAutofocus) { _, _ in
            updateAutomaticFocus()
        }
    }

    private func updateAutomaticFocus() {
        focusedInputID = isTrayExpanded && shouldAutofocus
            ? notification.presentation.inputs.first?.id
            : nil
    }

    private func valueBinding(
        for input: TerminalNotificationPresentation.Input
    ) -> Binding<String> {
        Binding(
            get: { values[input.id] ?? input.initialValue },
            set: { values[input.id] = $0 }
        )
    }

    private func actionButton(
        _ action: TerminalNotificationPresentation.Action
    ) -> some View {
        Button(action.title) {
            performAction(action.id, values)
        }
        .controlSize(.small)
        .accessibilityIdentifier("DynamicNotchNotificationAction.\(action.id)")
    }
}

private struct DynamicNotchInputAppearanceModifier: ViewModifier {
    let appearance: DynamicNotchAppearance

    @ViewBuilder
    func body(content: Content) -> some View {
        if appearance.usesNativeInputStyle {
            content
        } else {
            content
                .textFieldStyle(.plain)
                .foregroundStyle(
                    appearance.color(.inputTextColor, system: .primary)
                )
                .padding(
                    .horizontal,
                    appearance.dimension(.inputHorizontalPadding)
                )
                .padding(
                    .vertical,
                    appearance.dimension(.inputVerticalPadding)
                )
                .background(
                    appearance.color(
                        .inputBackgroundColor,
                        system: Color(nsColor: .textBackgroundColor)
                    )
                    .opacity(Double(appearance.dimension(.inputBackgroundOpacity))),
                    in: RoundedRectangle(
                        cornerRadius: appearance.dimension(.inputCornerRadius),
                        style: .continuous
                    )
                )
                .overlay {
                    RoundedRectangle(
                        cornerRadius: appearance.dimension(.inputCornerRadius),
                        style: .continuous
                    )
                    .stroke(
                        appearance.color(
                            .inputBorderColor,
                            system: Color(nsColor: .separatorColor)
                        ),
                        lineWidth: appearance.dimension(.inputBorderWidth)
                    )
                }
        }
    }
}
