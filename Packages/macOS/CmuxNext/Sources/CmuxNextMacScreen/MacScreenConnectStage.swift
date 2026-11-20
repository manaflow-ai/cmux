import Foundation

/// What a viewer's connect waits for next (cmuxterm-hq#13721): the host's answer, then the
/// secure link, then the first picture. ``MacScreenSession`` gives a connect 15 s to show a
/// picture; past that it fails with the stage it was in, so the card says where it stopped
/// instead of "Connecting..." forever.
public nonisolated enum MacScreenConnectStage: Int, Sendable, Comparable {
    /// The offer went; the host's answer has not come.
    case answer
    /// The host answered; the link to it is not up.
    case link
    /// The link is up; no picture has shown.
    case frame
    /// A picture showed: the connect is done.
    case shown

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// The stage's name in the log and `mac_screen.state`.
    public var name: String {
        switch self {
        case .answer: "no_answer"
        case .link: "no_link"
        case .frame: "no_frame"
        case .shown: "shown"
        }
    }

    /// The failed card's text for a connect that timed out in this stage; nil once shown.
    public func timeoutDetail(name: String) -> String? {
        switch self {
        case .answer: String(format: L.t("macScreen.card.noAnswer", "No answer from %@ within 15 seconds."), name)
        case .link: String(format: L.t("macScreen.card.noLink", "%@ answered, but no link came up within 15 seconds."), name)
        case .frame: String(format: L.t("macScreen.card.noFrame", "Connected to %@, but no picture arrived within 15 seconds."), name)
        case .shown: nil
        }
    }
}
