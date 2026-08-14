internal import Foundation

/// Sentry transport lifecycle storage, called only by the reporter's serialized
/// consent lifecycle command consumer.
final class MobileCrashTransportSessionController: MobileCrashTransportSessionControlling {
    private var session: URLSession?

    func makeSession() -> URLSession {
        let nextSession = URLSession(configuration: .ephemeral)
        let previousSession = session
        session = nextSession
        previousSession?.invalidateAndCancel()
        return nextSession
    }

    func invalidateAndCancel() {
        let session = session
        self.session = nil
        session?.invalidateAndCancel()
    }
}
