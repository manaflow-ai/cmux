public import CmuxNextDesign

/// Debug Settings declarations of the remote desktop pane.
public nonisolated enum RemoteViewTunables {
    public static let section = TunableSection(id: "remoteDesktop", title: "Remote Desktop", symbol: "display", order: 41)

    public static let presenter = Tunable<RemotePresenterKind>.choice(
        "remoteDesktop.debug.presenter", section, "Presenter",
        help: "How decoded frames reach the screen. Applies to panes opened after the change.",
        default: .metal, code: "RemoteViewTunables.presenter")

    public static var all: [TunableDescriptor] { [presenter.descriptor] }
}
