public import SwiftUI
public import CmuxNextDesignTokens

/// The SwiftUI twin of ``CmuxDialogButtonView``'s look: a dialog, sheet or popover button drawn in the
/// theme's ``CmuxDialogButtonLook`` (every ink at least 4.5:1 on its fill), never the system bezel.
///
/// SwiftUI's default button draws AppKit's bezel in the system appearance and takes its label ink
/// from the tint: in the bookmark editor's popover, tinted with the theme's selection fill, More…
/// and Remove read as nearly invisible (user 2026-11-20). Set it on a container and every button in
/// it that sets no style of its own takes it; the theme comes from ``SwiftUICore/EnvironmentValues/cmuxThemeTokens``.
///
/// ```swift
/// HStack {
///     Button(BookmarkStrings.remove) { model.onRemove() }
///     CmuxDialogActionButton(BookmarkStrings.done, hint: .return) { model.onDone() }
/// }
/// .buttonStyle(.cmuxDialog)
/// .cmuxThemeTokens(tokens)
/// ```
public struct CmuxDialogButtonStyle: ButtonStyle {
    /// The role it draws; nil takes the button's own (a destructive or cancel `ButtonRole`, else normal).
    public var role: CmuxDialogButton.Role?

    /// - Parameter role: The look's role; nil follows each button's `ButtonRole`.
    public init(role: CmuxDialogButton.Role? = nil) {
        self.role = role
    }

    public func makeBody(configuration: Configuration) -> some View {
        let role = role ?? (configuration.role == .destructive ? .destructive : configuration.role == .cancel ? .cancel : .normal)
        return CmuxDialogButtonBody(label: configuration.label, role: role, isPressed: configuration.isPressed)
    }
}

extension ButtonStyle where Self == CmuxDialogButtonStyle {
    /// ``CmuxDialogButtonStyle`` following each button's role.
    public static var cmuxDialog: CmuxDialogButtonStyle { CmuxDialogButtonStyle() }
}

/// One button of ``CmuxDialogButtonStyle``: the look for its role, hover and press, in the environment's theme.
private struct CmuxDialogButtonBody<Label: View>: View {
    let label: Label
    let role: CmuxDialogButton.Role
    let isPressed: Bool
    @Environment(\.cmuxThemeTokens) private var tokens
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        let state: CmuxDialogButtonLook.State = isPressed ? .pressed : isHovering && isEnabled ? .hover : .rest
        let look = CmuxDialogButtonLook(role: role, tokens: tokens ?? .unresolved, state: state)
        label
            .font(Font(role == .default ? Typography.bodyEmphasized : Typography.body))
            .foregroundStyle(look.title.swiftUIColor)
            .lineLimit(1)
            .padding(.horizontal, Metrics.space5)
            .frame(minWidth: CmuxDialogMetrics.buttonMinWidth, minHeight: CmuxDialogMetrics.buttonHeight)
            .background(look.fill.swiftUIColor, in: RoundedRectangle(cornerRadius: Metrics.buttonCornerRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Metrics.buttonCornerRadius, style: .continuous))
            // A disabled button dims as a whole, as ``CmuxDialogButtonView`` does, and stays legible.
            .opacity(isEnabled ? 1 : CmuxDialogButtonLook.disabledOpacity)
            .onHover { isHovering = $0 }
    }
}
