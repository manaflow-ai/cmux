/// Where what an agent chat opens goes (a link clicked in it, a chat or session it opens): the one switch
/// for it. Leo 2026-10-29: "I open a link ... it opens up on the right by default. Then just open it up on
/// the fucking right." Leo 2026-10-30: "stupid to not reuse the existing opened fucking right pane".
/// Either way the tab is made where it ends up, never in one pane and then moved to another (Leo
/// 2026-10-30: "IT'S THE FUCKING SINGLE MAIN TO OTHER FUCKING").
enum ChatOpenDestination: Equatable {
    /// The pane already on the chat's right, when there is one (else the open's usual route).
    case rightPane
    /// The chat's own pane.
    case chatPane

    /// The destination in effect.
    static let current: ChatOpenDestination = .rightPane
}
