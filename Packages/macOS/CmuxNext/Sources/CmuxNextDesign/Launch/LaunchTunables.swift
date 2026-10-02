/// The Debug Settings switches for the launch load-in.
public nonisolated enum LaunchTunables {
    public static let markStyle = Tunable<LaunchMarkStyle>.choice(
        "launch.markStyle", .sidebar, "Launch mark",
        help: "How the cmux mark resolves on the glass while a launch has nothing to show yet.",
        default: .bloom, code: "LaunchTunables.markStyle")

    public static var all: [TunableDescriptor] { [markStyle.descriptor] + MotionTunables.launchDelays.map(\.descriptor) }
}
