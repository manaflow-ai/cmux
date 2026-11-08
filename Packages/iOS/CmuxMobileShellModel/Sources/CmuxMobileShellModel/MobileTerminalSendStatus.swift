/// User-visible settlement state for a terminal submission.
///
/// The state is scoped per terminal and covers both the composer paste path and
/// Return-terminated raw terminal commands. Ordinary keystrokes are excluded so
/// typing does not flash transport chrome for every character.
public enum MobileTerminalSendStatus: Equatable, Sendable {
    case idle
    case sending
    case sent
    case failed
}
