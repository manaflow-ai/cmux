/// Takes problems as they happen: the app's ``ErrorJournal``, or a test's recorder.
///
/// The app's composition root makes the one journal and passes it, as this protocol, to every
/// reporter (``ErrorReporter``, ``ConsoleErrorCapture``) through `init`; there is no shared
/// default. A test passes a recorder of its own:
///
/// ```swift
/// actor Recorded: ErrorRecording {
///     var events: [ErrorEvent] = []
///     func record(_ event: ErrorEvent) { events.append(event) }
/// }
/// ```
public protocol ErrorRecording: Sendable {
    /// Folds one occurrence into the journal; the journal writes it in its next batch.
    /// - Parameter event: What happened.
    func record(_ event: ErrorEvent) async
}

extension ErrorJournal: ErrorRecording {}
