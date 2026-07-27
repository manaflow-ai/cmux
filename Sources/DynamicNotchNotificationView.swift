import SwiftUI

/// Interactive content hosted by DynamicNotchKit for one terminal notification.
struct DynamicNotchNotificationView: View {
    let notification: TerminalNotification
    let performAction: (String, [String: String]) -> Void
    @State private var values: [String: String]
    @FocusState private var focusedInputID: String?

    init(
        notification: TerminalNotification,
        performAction: @escaping (String, [String: String]) -> Void
    ) {
        self.notification = notification
        self.performAction = performAction
        _values = State(initialValue: Dictionary(
            uniqueKeysWithValues: notification.presentation.inputs.map {
                ($0.id, $0.initialValue)
            }
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: notification.presentation.iconSymbolName ?? "bell.badge.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 30, height: 30)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(notification.title)
                        .font(.headline)
                        .lineLimit(2)
                    if !notification.subtitle.isEmpty {
                        Text(notification.subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if !notification.body.isEmpty {
                        Text(notification.body)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    performAction("dismiss", values)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel(String(localized: "notification.dynamicNotch.dismiss", defaultValue: "Dismiss"))
                .accessibilityIdentifier("DynamicNotchNotificationDismiss")
            }

            if !notification.presentation.inputs.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(notification.presentation.inputs, id: \.id) { input in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(input.label)
                                .font(.caption)
                                .foregroundStyle(.secondary)
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
                        }
                        .accessibilityIdentifier("DynamicNotchNotificationInput.\(input.id)")
                    }
                }
            }

            HStack(spacing: 8) {
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
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 18)
        .frame(width: 430)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("DynamicNotchNotification")
        .onAppear {
            focusedInputID = notification.presentation.inputs.first?.id
        }
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
