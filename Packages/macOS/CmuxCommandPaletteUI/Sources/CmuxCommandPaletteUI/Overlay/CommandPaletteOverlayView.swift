public import SwiftUI
public import CmuxCommandPalette

/// The command-palette overlay: a click-catching backdrop behind a centered,
/// rounded, shadowed card whose body switches on the palette's input mode.
///
/// Lifted out of `ContentView` so the palette's overlay body is an explicit-typed
/// `View` struct in the command-palette UI package. The mode switch is driven by
/// the package `CommandPalettePresentationModel.mode`; the `.commands` mode renders
/// the package `CommandPaletteCommandListView`, while the three editor modes render
/// host-provided content (the rename/confirm/description input views stay app-side
/// because they resolve localized strings and app appearance tokens). Backdrop
/// clicks and dismissal are injected closures so the overlay never reaches back
/// into the app target.
public struct CommandPaletteOverlayView<
    CommandsContent: View,
    RenameInputContent: View,
    RenameConfirmContent: View,
    WorkspaceDescriptionContent: View
>: View {
    @Bindable private var presentation: CommandPalettePresentationModel
    private let onBackdropClick: (CGPoint) -> Void
    private let onDismiss: () -> Void
    @ViewBuilder private let commandsContent: () -> CommandsContent
    @ViewBuilder private let renameInputContent: (CommandPaletteRenameTarget) -> RenameInputContent
    @ViewBuilder private let renameConfirmContent: (CommandPaletteRenameTarget, String) -> RenameConfirmContent
    @ViewBuilder private let workspaceDescriptionContent: (CommandPaletteWorkspaceDescriptionTarget, CGFloat) -> WorkspaceDescriptionContent

    /// Creates the overlay.
    /// - Parameters:
    ///   - presentation: The palette presentation model; its `mode` selects the card body.
    ///   - onBackdropClick: Invoked with the content-space point of a backdrop click.
    ///   - onDismiss: Dismisses the palette (Escape / hidden cancel button).
    ///   - commandsContent: The `.commands` mode body (the command/switcher list).
    ///   - renameInputContent: The `.renameInput` body for the given target.
    ///   - renameConfirmContent: The `.renameConfirm` body for the target and proposed name.
    ///   - workspaceDescriptionContent: The `.workspaceDescriptionInput` body for the target and computed max editor height.
    public init(
        presentation: CommandPalettePresentationModel,
        onBackdropClick: @escaping (CGPoint) -> Void,
        onDismiss: @escaping () -> Void,
        @ViewBuilder commandsContent: @escaping () -> CommandsContent,
        @ViewBuilder renameInputContent: @escaping (CommandPaletteRenameTarget) -> RenameInputContent,
        @ViewBuilder renameConfirmContent: @escaping (CommandPaletteRenameTarget, String) -> RenameConfirmContent,
        @ViewBuilder workspaceDescriptionContent: @escaping (CommandPaletteWorkspaceDescriptionTarget, CGFloat) -> WorkspaceDescriptionContent
    ) {
        self._presentation = Bindable(presentation)
        self.onBackdropClick = onBackdropClick
        self.onDismiss = onDismiss
        self.commandsContent = commandsContent
        self.renameInputContent = renameInputContent
        self.renameConfirmContent = renameConfirmContent
        self.workspaceDescriptionContent = workspaceDescriptionContent
    }

    public var body: some View {
        GeometryReader { proxy in
            let maxAllowedWidth = max(340, proxy.size.width - 260)
            let targetWidth = min(560, maxAllowedWidth)
            let workspaceDescriptionMaxEditorHeight = max(
                CommandPaletteMultilineTextEditorRepresentable.defaultMinimumHeight,
                proxy.size.height - 120
            )

            ZStack(alignment: .top) {
                Color.clear
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onEnded { value in
                                onBackdropClick(value.location)
                            }
                    )

                Color.clear
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("CommandPaletteBackdrop")

                VStack(spacing: 0) {
                    switch presentation.mode {
                    case .commands:
                        commandsContent()
                    case .renameInput(let target):
                        renameInputContent(target)
                    case let .renameConfirm(target, proposedName):
                        renameConfirmContent(target, proposedName)
                    case .workspaceDescriptionInput(let target):
                        workspaceDescriptionContent(target, workspaceDescriptionMaxEditorHeight)
                    }
                }
                .frame(width: targetWidth)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .windowBackgroundColor).opacity(0.98))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.24), radius: 10, x: 0, y: 5)
                .padding(.top, 40)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onExitCommand {
            onDismiss()
        }
        .zIndex(2000)
    }
}
