public import CmuxNextDesign

/// Debug Settings declarations of the remote desktop pane.
public struct RemoteViewTunables {
    public nonisolated let section: TunableSection
    public nonisolated let presenter: Tunable<RemotePresenterKind>

    public nonisolated init() {
        section = TunableSection(id: "remoteDesktop", title: "Remote Desktop", symbol: "display", order: 41)
        presenter = Tunable<RemotePresenterKind>.choice(
            "remoteDesktop.debug.presenter", section, "Presenter",
            help: "How decoded frames reach the screen. Applies to panes opened after the change.",
            default: .metal, code: "RemoteViewTunables.presenter")
    }

    public nonisolated var all: [TunableDescriptor] { [presenter.descriptor] }
}
