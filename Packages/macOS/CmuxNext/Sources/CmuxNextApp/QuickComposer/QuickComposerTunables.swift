import CmuxNextDesign

/// Start Agent's floating chat (cx-b9qi), off until it is styled into the app.
nonisolated enum QuickComposerTunables {
    static let floatingChat = Tunable<Bool>.toggle(
        "quickComposer.floatingChat", .palette, "Floating chat",
        help: "Start Agent's chat stays in its panel once it starts and keeps running there: the panel stays up when you click away, drags and resizes, and remembers its frame on each screen (prototype).",
        default: false, code: "QuickComposerTunables.floatingChat")

    static var all: [TunableDescriptor] { [floatingChat.descriptor] }
}
