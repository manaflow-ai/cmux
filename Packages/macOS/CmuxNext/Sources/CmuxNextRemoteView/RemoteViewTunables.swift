public import CmuxNextDesign

/// Debug Settings declarations of the remote desktop pane.
public struct RemoteViewTunables {
    public let section: TunableSection
    public let presenter: Tunable<RemotePresenterKind>

    public init() {
        section = TunableSection(id: "remoteDesktop", title: "Remote Desktop", symbol: "display", order: 41)
        presenter = Tunable<RemotePresenterKind>.choice(
            "remoteDesktop.debug.presenter", section, "Presenter",
            help: "How decoded frames reach the screen. Applies to panes opened after the change.",
            default: .metal, code: "RemoteViewTunables.presenter")
    }

    public var all: [TunableDescriptor] { [presenter.descriptor] }
}
