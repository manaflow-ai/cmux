/// The choices every chat's place control offers (`place.modes` in `pane.tabState`), read again each time
/// it changes. Settings > Experiments' Cloud Toggle (`experiments.cloudToggle`): Local, Cloud and Auto.
/// Else AutoCloud (`cloud.autoCloud`, Settings > Machines): AutoCloud on or off for this one chat, Auto or
/// Local, both ways while it lives. A chat with no pick stays Local: AutoCloud is an option per chat,
/// never every chat's default (Leo, 2026-11-27: "we're not putting autocloud as THE DEFAULT OPTION FOR
/// EVERY SINGLE CHAT. IT JUST SIMPLY MUST BE AN OPTION."; "remember we need to be able to toggle a chat
/// on and off of autocloud"). Neither: none, and the control is hidden.
extension CmuxConfigSnapshot {
    public var placeModes: [String] {
        Self.placeModes(cloudToggle: experimentSwitches["cloudToggle"] == true, autoCloud: CloudNewWorkspaceSetting().autoCloud(in: root))
    }

    public nonisolated static func placeModes(cloudToggle: Bool, autoCloud: Bool) -> [String] {
        cloudToggle ? ["local", "cloud", "auto"] : autoCloud ? ["local", "auto"] : []
    }
}
