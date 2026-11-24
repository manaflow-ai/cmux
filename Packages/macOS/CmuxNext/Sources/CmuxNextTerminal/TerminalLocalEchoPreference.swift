import CmuxNextCompat
import Foundation

/// `terminal.predictiveLocalEcho` for an app's terminals. The setting lives in CmuxNextSettings; the app hands its
/// value in (``follow(_:)``). Every session made with this preference starts from its value and follows each change
/// (``TerminalSession/predictsLocalEcho``), so turning it off takes the glyphs out of running remote terminals at once.
@MainActor
public final class TerminalLocalEchoPreference {
    public private(set) var predicts: Bool
    /// The sessions that follow it; weak, so a closed session leaves on its own.
    private let sessions = NSHashTable<TerminalSession>.weakObjects()

    public init(predicts: Bool = true) {
        self.predicts = predicts
    }

    public func set(_ predicts: Bool) {
        guard predicts != self.predicts else { return }
        self.predicts = predicts
        for session in sessions.allObjects { session.predictsLocalEcho = predicts }
    }

    /// Keeps the value at `read`, an observable read such as the settings snapshot's key.
    public func follow(_ read: @escaping @MainActor @Sendable () -> Bool) {
        // task-owner: lives as long as the app's settings; ends once the preference is gone and the value changes.
        Task { [weak self] in
            for await predicts in ObservationStream(read) {
                guard let self else { return }
                set(predicts)
            }
        }
    }

    func adopt(_ session: TerminalSession) {
        session.predictsLocalEcho = predicts
        sessions.add(session)
    }
}
